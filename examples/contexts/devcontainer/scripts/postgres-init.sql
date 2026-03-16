-- Development database initialization
-- Creates the dev user and database referenced in docker-compose.yml
-- (DATABASE_URL=postgresql://dev:dev@postgres:5432/dev_db)

CREATE USER dev WITH PASSWORD 'dev';
CREATE DATABASE dev_db OWNER dev;

-- Grant full privileges for local development
GRANT ALL PRIVILEGES ON DATABASE dev_db TO dev;

-- Connect to dev_db and set up defaults
\c dev_db

-- Allow dev user to create schemas and tables
GRANT ALL ON SCHEMA public TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO dev;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO dev;

-- Enable common extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";
