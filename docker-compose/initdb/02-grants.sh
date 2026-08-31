#!/bin/sh
# PostgreSQL 15+ removes CREATE on the public schema from ordinary roles, so the
# owner has to be set explicitly or Hydra's migration fails.
set -e
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d hydra <<EOSQL
  ALTER DATABASE hydra OWNER TO "$POSTGRES_USER";
  ALTER SCHEMA public OWNER TO "$POSTGRES_USER";
  GRANT ALL ON SCHEMA public TO "$POSTGRES_USER";
EOSQL
echo "hydra database prepared for $POSTGRES_USER"
