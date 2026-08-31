-- Runs once, the first time the postgres volume is created.
-- POSTGRES_DB / POSTGRES_USER already made the application database and role;
-- Hydra needs a second database owned by that same role.
CREATE DATABASE hydra;
