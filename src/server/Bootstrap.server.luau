--!strict
-- Black Meridian server entry point (BM-001).
--
-- Deliberately empty of gameplay. Later tasks wire startup here in this order:
--   1. Content registries, configuration, schema validation
--   2. Persistence, lease, and reward infrastructure
--   3. Gameplay services
--   4. Request adapters and the remote dispatcher
--   5. Player session activation
--
-- This script must never create remotes, touch DataStores, or grant anything
-- until the task that owns that behaviour lands.

print("[BlackMeridian] Server bootstrap loaded")
