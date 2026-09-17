#include "postgres.h"
#include "fmgr.h"
#include "funcapi.h"
#include "access/htup_details.h"
#include "catalog/pg_type_d.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"
#include "utils/typcache.h"
#include "access/relation.h"
#include "common/int.h"

#include "pg_metal_backend.h"

PG_MODULE_MAGIC;

void _PG_init(void);
PG_FUNCTION_INFO_V1(pg_metal_device);
PG_FUNCTION_INFO_V1(pg_metal_stats);
PG_FUNCTION_INFO_V1(pg_metal_scan);
PG_FUNCTION_INFO_V1(pg_metal_sum_trans);
PG_FUNCTION_INFO_V1(pg_metal_sum_final);

enum { PG_METAL_AUTO, PG_METAL_CPU, PG_METAL_METAL };
static int backend_mode = PG_METAL_AUTO;
static int min_gpu_rows = 262144;
static int batch_rows = 262144;
static const struct config_enum_entry backend_options[] = {
    {"auto", PG_METAL_AUTO, false}, {"cpu", PG_METAL_CPU, false},
    {"metal", PG_METAL_METAL, false}, {NULL, 0, false}
};

typedef struct PgMetalAccumulator {
    PgMetalResult result;
    int64 rows;
    bool used_cpu;
    bool used_metal;
    bool metal_failed;
} PgMetalAccumulator;

typedef struct PgMetalSumState {
    PgMetalAccumulator acc;
    int32 *values;
    int capacity;
    int used;
    int target;
} PgMetalSumState;

void
_PG_init(void)
{
    DefineCustomEnumVariable("pg_metal.backend", "Execution backend for integer analytics.",
                             "Forced metal errors if GPU execution is unavailable.",
                             &backend_mode, PG_METAL_AUTO, backend_options,
                             PGC_USERSET, 0, NULL, NULL, NULL);
    DefineCustomIntVariable("pg_metal.min_gpu_rows", "Minimum batch size for automatic GPU execution.",
                            NULL, &min_gpu_rows, 262144, 0, 1048576,
                            PGC_USERSET, 0, NULL, NULL, NULL);
    DefineCustomIntVariable("pg_metal.batch_rows", "Maximum input rows in each analytics batch.",
                            NULL, &batch_rows, 262144, 256, 1048576,
                            PGC_USERSET, 0, NULL, NULL, NULL);
}

static void
merge_result(PgMetalAccumulator *acc, const PgMetalResult *part, int64 rows)
{
    int64 next;

    if (pg_add_s64_overflow(acc->rows, rows, &next))
        ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE), errmsg("pg_metal row count exceeds bigint")));
    acc->rows = next;
    if (part->count > 0)
    {
        if (acc->result.count == 0 || part->min < acc->result.min)
            acc->result.min = part->min;
        if (acc->result.count == 0 || part->max > acc->result.max)
            acc->result.max = part->max;
        if (pg_add_s64_overflow(acc->result.sum, part->sum, &next))
            ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE), errmsg("pg_metal sum exceeds bigint")));
        acc->result.sum = next;
        if (pg_add_s64_overflow(acc->result.count, part->count, &next))
            ereport(ERROR, (errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE), errmsg("pg_metal count exceeds bigint")));
        acc->result.count = next;
    }
    acc->result.gpu_ms += part->gpu_ms;
}

static void
reduce_batch(PgMetalAccumulator *acc, const int32 *values, const uint8 *valid,
             int size, bool has_lo, int32 lo, bool has_hi, int32 hi)
{
    PgMetalResult part;
    bool use_metal;
    bool succeeded = false;
    char device[256];
    char error[512];

    if (size == 0)
        return;
    CHECK_FOR_INTERRUPTS();
    error[0] = '\0';
    use_metal = backend_mode == PG_METAL_METAL ||
        (backend_mode == PG_METAL_AUTO && size >= min_gpu_rows && !acc->metal_failed);
    if (use_metal)
    {
        if (pg_metal_metal_available(device, sizeof(device), error, sizeof(error)))
            succeeded = pg_metal_metal_reduce(values, valid, (size_t) size,
                                         has_lo, lo, has_hi, hi, &part,
                                         error, sizeof(error));
        if (!succeeded)
        {
            if (backend_mode == PG_METAL_METAL)
                ereport(ERROR, (errcode(ERRCODE_EXTERNAL_ROUTINE_EXCEPTION),
                                errmsg("pg_metal Metal execution failed"),
                                errdetail("%s", error[0] ? error : "No Metal device is available.")));
            acc->metal_failed = true;
        }
    }
    if (succeeded)
        acc->used_metal = true;
    else
    {
        pg_metal_cpu_reduce(values, valid, (size_t) size, has_lo, lo, has_hi, hi, &part);
        acc->used_cpu = true;
    }
    CHECK_FOR_INTERRUPTS();
    merge_result(acc, &part, size);
}

static Datum
result_datum(FunctionCallInfo fcinfo, const PgMetalAccumulator *acc)
{
    TupleDesc desc;
    Datum fields[7];
    bool nulls[7] = {false, false, false, false, false, false, false};
    const char *backend;
    HeapTuple tuple;

    if (get_call_result_type(fcinfo, NULL, &desc) != TYPEFUNC_COMPOSITE)
        ereport(ERROR, (errmsg("pg_metal function requires a composite result type")));
    BlessTupleDesc(desc);
    backend = acc->used_metal ? (acc->used_cpu ? "mixed" : "metal") : "cpu";
    fields[0] = Int64GetDatum(acc->result.count);
    fields[1] = Int64GetDatum(acc->result.sum);
    fields[2] = Int32GetDatum(acc->result.min);
    fields[3] = Int32GetDatum(acc->result.max);
    fields[4] = CStringGetTextDatum(backend);
    fields[5] = Int64GetDatum(acc->rows);
    fields[6] = Float8GetDatum(acc->result.gpu_ms);
    if (acc->result.count == 0)
        nulls[1] = nulls[2] = nulls[3] = true;
    tuple = heap_form_tuple(desc, fields, nulls);
    return HeapTupleGetDatum(tuple);
}

Datum
pg_metal_device(PG_FUNCTION_ARGS)
{
    char device[256];
    char error[512];

    if (pg_metal_metal_available(device, sizeof(device), error, sizeof(error)))
        PG_RETURN_TEXT_P(cstring_to_text(device));
    PG_RETURN_TEXT_P(cstring_to_text(psprintf("unavailable: %s", error)));
}

Datum
pg_metal_stats(PG_FUNCTION_ARGS)
{
    ArrayType *array;
    ArrayIterator iterator;
    int32 *values;
    uint8 *valid;
    int used = 0;
    int target = batch_rows;
    Datum value;
    bool isnull;
    bool has_lo = !PG_ARGISNULL(1);
    bool has_hi = !PG_ARGISNULL(2);
    int32 lo = has_lo ? PG_GETARG_INT32(1) : 0;
    int32 hi = has_hi ? PG_GETARG_INT32(2) : 0;
    PgMetalAccumulator acc = {0};
    Datum result;

    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();
    array = PG_GETARG_ARRAYTYPE_P(0);
    /* A NULL-free int4 array is already a contiguous, aligned column. */
    if (!ARR_HASNULL(array))
    {
        int count = ArrayGetNItems(ARR_NDIM(array), ARR_DIMS(array));
        int offset;
        const int32 *packed = (const int32 *) ARR_DATA_PTR(array);

        for (offset = 0; offset < count;)
        {
            int size = Min(target, count - offset);

            reduce_batch(&acc, packed + offset, NULL, size, has_lo, lo, has_hi, hi);
            offset += size;
        }
        result = result_datum(fcinfo, &acc);
        PG_FREE_IF_COPY(array, 0);
        PG_RETURN_DATUM(result);
    }
    values = palloc(sizeof(int32) * target);
    valid = palloc(sizeof(uint8) * target);
    iterator = array_create_iterator(array, 0, NULL);
    while (array_iterate(iterator, &value, &isnull))
    {
        values[used] = isnull ? 0 : DatumGetInt32(value);
        valid[used++] = isnull ? 0 : 1;
        if (used == target)
        {
            reduce_batch(&acc, values, valid, used, has_lo, lo, has_hi, hi);
            used = 0;
        }
    }
    reduce_batch(&acc, values, valid, used, has_lo, lo, has_hi, hi);
    array_free_iterator(iterator);
    pfree(values);
    pfree(valid);
    PG_FREE_IF_COPY(array, 0);
    result = result_datum(fcinfo, &acc);
    PG_RETURN_DATUM(result);
}

Datum
pg_metal_scan(PG_FUNCTION_ARGS)
{
    Oid relid;
    Name column;
    Relation rel;
    AttrNumber attnum;
    char *qualified;
    char *query;
    Portal portal;
    SPIParseOpenOptions options = {0};
    int32 *values;
    uint8 *valid;
    int target = batch_rows;
    bool has_lo = !PG_ARGISNULL(2);
    bool has_hi = !PG_ARGISNULL(3);
    int32 lo = has_lo ? PG_GETARG_INT32(2) : 0;
    int32 hi = has_hi ? PG_GETARG_INT32(3) : 0;
    PgMetalAccumulator acc = {0};
    Datum result;

    if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
        PG_RETURN_NULL();
    relid = PG_GETARG_OID(0);
    column = PG_GETARG_NAME(1);
    rel = relation_open(relid, AccessShareLock);
    attnum = get_attnum(relid, NameStr(*column));
    if (attnum == InvalidAttrNumber)
        ereport(ERROR, (errcode(ERRCODE_UNDEFINED_COLUMN),
                        errmsg("column \"%s\" does not exist", NameStr(*column))));
    if (get_atttype(relid, attnum) != INT4OID)
        ereport(ERROR, (errcode(ERRCODE_DATATYPE_MISMATCH),
                        errmsg("pg_metal_scan requires an integer (int4) column")));
    qualified = quote_qualified_identifier(get_namespace_name(RelationGetNamespace(rel)),
                                           RelationGetRelationName(rel));
    query = psprintf("SELECT %s FROM %s", quote_identifier(NameStr(*column)), qualified);
    relation_close(rel, NoLock);
    values = palloc(sizeof(int32) * target);
    valid = palloc(sizeof(uint8) * target);
    if (SPI_connect() != SPI_OK_CONNECT)
        ereport(ERROR, (errmsg("pg_metal could not connect to SPI")));
    options.read_only = true;
    portal = SPI_cursor_parse_open(NULL, query, &options);
    for (;;)
    {
        uint64 size;
        uint64 i;

        CHECK_FOR_INTERRUPTS();
        SPI_cursor_fetch(portal, true, target);
        size = SPI_processed;
        if (size == 0)
        {
            if (SPI_tuptable)
                SPI_freetuptable(SPI_tuptable);
            break;
        }
        for (i = 0; i < size; i++)
        {
            bool isnull;
            Datum value = SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 1, &isnull);

            values[i] = isnull ? 0 : DatumGetInt32(value);
            valid[i] = isnull ? 0 : 1;
        }
        SPI_freetuptable(SPI_tuptable);
        reduce_batch(&acc, values, valid, (int) size, has_lo, lo, has_hi, hi);
    }
    SPI_cursor_close(portal);
    SPI_finish();
    pfree(values);
    pfree(valid);
    pfree(query);
    pfree(qualified);
    result = result_datum(fcinfo, &acc);
    PG_RETURN_DATUM(result);
}

Datum
pg_metal_sum_trans(PG_FUNCTION_ARGS)
{
    MemoryContext agg_context;
    MemoryContext previous;
    PgMetalSumState *state;

    if (!AggCheckCallContext(fcinfo, &agg_context))
        ereport(ERROR, (errmsg("pg_metal_sum_trans may only be called as an aggregate")));
    if (PG_ARGISNULL(1))
    {
        if (PG_ARGISNULL(0))
            PG_RETURN_NULL();
        PG_RETURN_POINTER(PG_GETARG_POINTER(0));
    }
    if (PG_ARGISNULL(0))
    {
        previous = MemoryContextSwitchTo(agg_context);
        state = palloc0(sizeof(PgMetalSumState));
        state->target = batch_rows;
        state->capacity = Min(256, state->target);
        state->values = palloc(sizeof(int32) * state->capacity);
        MemoryContextSwitchTo(previous);
    }
    else
        state = (PgMetalSumState *) PG_GETARG_POINTER(0);
    if (state->used == state->capacity)
    {
        state->capacity = Min(state->capacity * 2, state->target);
        state->values = repalloc(state->values, sizeof(int32) * state->capacity);
    }
    state->values[state->used++] = PG_GETARG_INT32(1);
    if (state->used == state->target)
    {
        reduce_batch(&state->acc, state->values, NULL, state->used, false, 0, false, 0);
        state->used = 0;
    }
    PG_RETURN_POINTER(state);
}

Datum
pg_metal_sum_final(PG_FUNCTION_ARGS)
{
    PgMetalSumState *state;
    PgMetalAccumulator acc;

    if (!AggCheckCallContext(fcinfo, NULL))
        ereport(ERROR, (errmsg("pg_metal_sum_final may only be called as an aggregate")));
    if (PG_ARGISNULL(0))
        PG_RETURN_NULL();
    state = (PgMetalSumState *) PG_GETARG_POINTER(0);
    acc = state->acc;
    reduce_batch(&acc, state->values, NULL, state->used, false, 0, false, 0);
    PG_RETURN_INT64(acc.result.sum);
}
