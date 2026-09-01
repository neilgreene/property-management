#!/usr/bin/env python3
"""
Snapshots the live database schema to docs/schema-snapshot.json.

The documentation generator reads that snapshot rather than querying a
database, so the PDF can be rebuilt on a machine with no PostgreSQL running.
Re-run this after any schema change, then regenerate the PDF:

    ./run.sh                                     # or docker compose up
    python3 docs/extract_schema.py
    python3 docs/generate_system_documentation.py
"""
import json
import subprocess
import sys

DB = sys.argv[1] if len(sys.argv) > 1 else "sdi"
OUT = "docs/schema-snapshot.json"

COLUMNS = """
SELECT c.table_schema AS s, c.table_name AS t, c.ordinal_position AS pos,
       c.column_name AS col,
       CASE
         WHEN c.data_type = 'character varying' AND c.character_maximum_length IS NOT NULL
              THEN 'varchar(' || c.character_maximum_length || ')'
         WHEN c.data_type = 'character' AND c.character_maximum_length IS NOT NULL
              THEN 'char(' || c.character_maximum_length || ')'
         WHEN c.data_type = 'numeric' AND c.numeric_precision IS NOT NULL
              THEN 'numeric(' || c.numeric_precision || ',' || COALESCE(c.numeric_scale,0) || ')'
         WHEN c.data_type = 'timestamp with time zone'    THEN 'timestamptz'
         WHEN c.data_type = 'timestamp without time zone' THEN 'timestamp'
         WHEN c.data_type = 'USER-DEFINED'                THEN c.udt_name
         WHEN c.data_type = 'integer'                     THEN 'integer'
         WHEN c.data_type = 'bigint'                      THEN 'bigint'
         WHEN c.data_type = 'smallint'                    THEN 'smallint'
         ELSE c.data_type
       END AS coltype,
       c.is_nullable AS nullable,
       COALESCE(c.column_default, '') AS coldefault,
       COALESCE(pgd.description, '') AS coldesc
FROM information_schema.columns c
JOIN pg_class cl ON cl.relname = c.table_name
JOIN pg_namespace ns ON ns.oid = cl.relnamespace AND ns.nspname = c.table_schema
LEFT JOIN pg_description pgd ON pgd.objoid = cl.oid AND pgd.objsubid = c.ordinal_position
WHERE c.table_schema IN ('core','ghl','feed')
  AND cl.relkind = 'r'
ORDER BY c.table_schema, c.table_name, c.ordinal_position;
"""

# Key/constraint role per column, collapsed to one short marker.
KEYS = """
SELECT n.nspname AS s, cl.relname AS t, a.attname AS c,
       string_agg(DISTINCT
         CASE con.contype WHEN 'p' THEN 'PK'
                          WHEN 'f' THEN 'FK'
                          WHEN 'u' THEN 'UQ'
                          WHEN 'c' THEN 'CK' END, ' ') AS k
FROM pg_constraint con
JOIN pg_class cl      ON cl.oid = con.conrelid
JOIN pg_namespace n   ON n.oid = cl.relnamespace
JOIN unnest(con.conkey) AS k(attnum) ON true
JOIN pg_attribute a   ON a.attrelid = cl.oid AND a.attnum = k.attnum
WHERE n.nspname IN ('core','ghl','feed')
GROUP BY 1,2,3;
"""

# Table-level comments, and the referenced table for each foreign key.
TABLES = """
SELECT n.nspname AS s, cl.relname AS t, COALESCE(obj_description(cl.oid), '') AS cmt,
       cl.relrowsecurity AS rls
FROM pg_class cl JOIN pg_namespace n ON n.oid = cl.relnamespace
WHERE n.nspname IN ('core','ghl','feed') AND cl.relkind = 'r'
ORDER BY 1,2;
"""

FKS = """
SELECT n.nspname AS s, cl.relname AS t, a.attname AS c,
       fn.nspname || '.' || fcl.relname AS ref
FROM pg_constraint con
JOIN pg_class cl     ON cl.oid = con.conrelid
JOIN pg_namespace n  ON n.oid = cl.relnamespace
JOIN pg_class fcl    ON fcl.oid = con.confrelid
JOIN pg_namespace fn ON fn.oid = fcl.relnamespace
JOIN unnest(con.conkey) AS k(attnum) ON true
JOIN pg_attribute a  ON a.attrelid = cl.oid AND a.attnum = k.attnum
WHERE con.contype = 'f' AND n.nspname IN ('core','ghl','feed');
"""


def q(sql):
    """Runs a query and returns rows as lists.

    The result comes back as JSON rather than delimited text: column comments
    contain newlines, which silently corrupt any line-based parse.
    """
    # The row alias must not collide with any column alias in the query --
    # json_agg(t) would otherwise aggregate a column called t rather than the row.
    wrapped = (f"SELECT coalesce(json_agg(_row), '[]'::json) "
               f"FROM ({sql.strip().rstrip(';')}) _row")
    out = subprocess.run(["psql", "-d", DB, "-At", "-c", wrapped],
                         capture_output=True, text=True, check=True).stdout
    return [list(row.values()) for row in json.loads(out)]


keys = {(s, t, c): k for s, t, c, k in q(KEYS)}
fks  = {(s, t, c): ref for s, t, c, ref in q(FKS)}

tables = {}
for schema, name, comment, rls in q(TABLES):
    tables[(schema, name)] = {
        "schema": schema, "name": name, "comment": comment,
        "rls": bool(rls), "columns": [],
    }

for schema, name, _pos, col, coltype, nullable, default, coldesc in q(COLUMNS):
    key = keys.get((schema, name, col), "")
    ref = fks.get((schema, name, col), "")
    tables[(schema, name)]["columns"].append({
        "name": col, "type": coltype,
        "nullable": nullable == "YES",
        "default": default,
        "key": key, "references": ref,
        "comment": coldesc,
    })

data = [tables[k] for k in sorted(tables)]
with open(OUT, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
print(f"wrote {OUT}: {len(data)} tables, "
      f"{sum(len(t['columns']) for t in data)} columns")
