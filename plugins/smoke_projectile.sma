/*
    plugins/smoke_projectile.sma
    Stage 1+2 - Projectile + Smoke Entity skeleton

    - Stage 1: projectile creation/movement/explosion (data-only)
    - Stage 2: spawn a single entity representing the smoke on explosion
      * entity: info_target with classname "valorant_smoke"
      * schedule a think for that entity and implement a minimal smoke_think

    Notes:
    - No sprites/particles yet. This file only creates the entity and keeps a minimal thinker.
    - Uses a single global task to update projectiles.
    - Keeps smoke data mapping to the entity for later expansion.
*/

#define PLUGIN_NAME "smoke_projectile"
#define PLUGIN_VERSION "0.2"

#define MAX_PLAYERS 32
#define MAX_SMOKES 64

// Projectile settings
#define PROJ_SPEED 900.0    // units per second
#define TASK_INTERVAL 0.02  // seconds per update (50 Hz)
#define MAX_RANGE 1400.0    // max travel distance before auto-explode

// Smoke core lifetime (data only)
#define SMOKE_LIFETIME 15.0 // seconds

new bool:g_bProjActive[MAX_PLAYERS+1];
new Float:g_fProjPos[MAX_PLAYERS+1][3];
new Float:g_fProjVel[MAX_PLAYERS+1][3];
new Float:g_fProjStartPos[MAX_PLAYERS+1][3];
new Float:g_fProjTraveled[MAX_PLAYERS+1];
new g_iProjTask = -1;

// Smoke core storage (maps to entity when available)
new bool:g_bSmokeActive[MAX_SMOKES];
new Float:g_fSmokeOrigin[MAX_SMOKES][3];
new Float:g_fSmokeCreateTime[MAX_SMOKES];
new Float:g_fSmokeExpireTime[MAX_SMOKES];
new g_iSmokeOwner[MAX_SMOKES];
new g_iSmokeEntity[MAX_SMOKES]; // entity index for this smoke (0 = none)

// Utility forward decls
forward void:OnPlayerPressProj(id);
forward void:OnPlayerReleaseProj(id);
forward UpdateProjectiles();
forward CreateSmokeEntity(Float:ox, Float:oy, Float:oz, ownerid);
forward smoke_think(ent);

public plugin_precache()
{
    // nothing to precache yet (no models/sounds)
}

public plugin_init()
{
    register_clcmd("+smoke", "OnPlayerPressProj");
    register_clcmd("-smoke", "OnPlayerReleaseProj");

    // start the global update task
    g_iProjTask = set_task(TASK_INTERVAL, "UpdateProjectiles", _, _, _, "");

    // register the think name so engine can call our smoke_think when an entity thinks
    // user suggested: register_think("valorant_smoke", "smoke_think")
    // depending on the mod include this might be register_think or register_entity_class; we attempt register_think if available.
    register_think("valorant_smoke", "smoke_think");

    log_event(true, PLUGIN_NAME " v" PLUGIN_VERSION " loaded.");
}

public plugin_end()
{
    if (g_iProjTask != -1)
    {
        kill_task(g_iProjTask);
        g_iProjTask = -1;
    }
}

public client_disconnect(id)
{
    if (g_bProjActive[id])
    {
        ExplodeProjectile(id);
    }
}

// Player pressed +smoke (should be bound by user: bind "c" "+smoke")
public void:OnPlayerPressProj(id)
{
    if (!is_user_connected(id) || !is_user_alive(id)) return;
    if (g_bProjActive[id]) return; // already have a proj

    new Float:origin[3];
    new Float:angles[3];
    get_user_origin(id, origin);
    get_user_angles(id, angles);

    // Compute forward vector from angles
    new Float:forward[3];
    AngleVectors(angles, forward, _, _);

    // Start projectile a little in front of the player's eyes
    g_fProjPos[id][0] = origin[0] + forward[0]*18.0;
    g_fProjPos[id][1] = origin[1] + forward[1]*18.0;
    g_fProjPos[id][2] = origin[2] + forward[2]*18.0 + 10.0; // eye offset

    g_fProjVel[id][0] = forward[0] * PROJ_SPEED;
    g_fProjVel[id][1] = forward[1] * PROJ_SPEED;
    g_fProjVel[id][2] = forward[2] * PROJ_SPEED;

    g_fProjStartPos[id][0] = g_fProjPos[id][0];
    g_fProjStartPos[id][1] = g_fProjPos[id][1];
    g_fProjStartPos[id][2] = g_fProjPos[id][2];

    g_fProjTraveled[id] = 0.0;

    g_bProjActive[id] = true;

    // Debug: notify player
    client_print(id, print_console, "[Smoke] Projectile created. Release to deploy.");
}

// Player released -smoke
public void:OnPlayerReleaseProj(id)
{
    if (!is_user_connected(id)) return;
    if (!g_bProjActive[id]) return;

    ExplodeProjectile(id);
}

// Explode projectile: create Smoke Entity and deactivate projectile
public ExplodeProjectile(id)
{
    if (!g_bProjActive[id]) return 0;

    new Float:ox = g_fProjPos[id][0];
    new Float:oy = g_fProjPos[id][1];
    new Float:oz = g_fProjPos[id][2];

    CreateSmokeEntity(ox, oy, oz, id);

    g_bProjActive[id] = false;
    g_fProjTraveled[id] = 0.0;

    // Debug
    client_print(id, print_console, "[Smoke] Exploded and spawned Smoke entity (data-only).");

    return 1;
}

// Create a smoke entity (info_target with classname valorant_smoke) and schedule its think
public CreateSmokeEntity(Float:ox, Float:oy, Float:oz, ownerid)
{
    // find free smoke slot
    new i;
    for (i = 0; i < MAX_SMOKES; i++)
    {
        if (!g_bSmokeActive[i]) break;
    }
    if (i >= MAX_SMOKES) {
        // recycle oldest
        i = 0;
    }

    // store data
    g_bSmokeActive[i] = true;
    g_fSmokeOrigin[i][0] = ox;
    g_fSmokeOrigin[i][1] = oy;
    g_fSmokeOrigin[i][2] = oz;
    g_fSmokeCreateTime[i] = get_gametime();
    g_fSmokeExpireTime[i] = g_fSmokeCreateTime[i] + SMOKE_LIFETIME;
    g_iSmokeOwner[i] = ownerid;
    g_iSmokeEntity[i] = 0;

    // Create entity in the world. We'll try to use engine-provided helpers per user's skeleton.
    new ent = create_entity("info_target");
    if (ent <= 0)
    {
        server_print("[Smoke] Failed to create entity for smoke %d", i);
        return -1;
    }

    // set classname (engine-specific keyvalues enum names used here as EV_SZ_classname)
    entity_set_string(ent, EV_SZ_classname, "valorant_smoke");

    // set origin
    entity_set_origin(ent, ox, oy, oz);

    // set nextthink shortly in the future
    entity_set_float(ent, EV_FL_nextthink, get_gametime() + 0.05);

    // store entity index
    g_iSmokeEntity[i] = ent;

    // register think callback name for this entity class if not already: we did register_think in plugin_init
    // the engine will call smoke_think(ent) when the entity's think fires.

    server_print("[Smoke] Spawned valorant_smoke entity %d for slot %d at (%.1f, %.1f, %.1f)", ent, i, ox, oy, oz);

    return i;
}

// Minimal smoke thinker skeleton. All behavior will be implemented here in future phases.
public smoke_think(ent)
{
    if (!is_valid_ent(ent))
    {
        return;
    }

    // Find which smoke slot this entity belongs to (simple linear search)
    new slot = -1;
    for (new i = 0; i < MAX_SMOKES; i++)
    {
        if (g_bSmokeActive[i] && g_iSmokeEntity[i] == ent)
        {
            slot = i;
            break;
        }
    }

    if (slot == -1)
    {
        // unknown entity: just schedule nextthink and return
        entity_set_float(ent, EV_FL_nextthink, get_gametime() + 0.05);
        return;
    }

    // If expired, remove entity and clear slot
    new Float:now = get_gametime();
    if (now >= g_fSmokeExpireTime[slot])
    {
        // remove entity
        remove_entity(ent);

        g_bSmokeActive[slot] = false;
        g_iSmokeEntity[slot] = 0;

        server_print("[Smoke] Smoke slot %d expired and removed.", slot);
        return;
    }

    // Placeholder for future updates:
    // - expand radius
    // - breathing/noise
    // - fade
    // - visibility updates (AddToFullPack + cache updates)
    // For now, we just reschedule the think.

    entity_set_float(ent, EV_FL_nextthink, now + 0.05);
}

// Global update task: moves all active projectiles. Single task -> Phase 7 ready.
public UpdateProjectiles()
{
    // We'll use TASK_INTERVAL as our dt
    new Float:dt = TASK_INTERVAL;

    for (new id = 1; id <= get_maxplayers(); id++)
    {
        if (!is_user_connected(id)) continue;

        if (g_bProjActive[id])
        {
            // Update projectile direction to follow player's crosshair
            if (is_user_alive(id))
            {
                new Float:angles[3];
                get_user_angles(id, angles);
                new Float:forward[3];
                AngleVectors(angles, forward, _, _);

                // update velocity to follow the crosshair
                g_fProjVel[id][0] = forward[0] * PROJ_SPEED;
                g_fProjVel[id][1] = forward[1] * PROJ_SPEED;
                g_fProjVel[id][2] = forward[2] * PROJ_SPEED;
            }

            // Move projectile
            g_fProjPos[id][0] += g_fProjVel[id][0] * dt;
            g_fProjPos[id][1] += g_fProjVel[id][1] * dt;
            g_fProjPos[id][2] += g_fProjVel[id][2] * dt;

            // Track distance traveled
            new Float:dx = g_fProjPos[id][0] - g_fProjStartPos[id][0];
            new Float:dy = g_fProjPos[id][1] - g_fProjStartPos[id][1];
            new Float:dz = g_fProjPos[id][2] - g_fProjStartPos[id][2];
            new Float:dist = floatsqrt(dx*dx + dy*dy + dz*dz);
            g_fProjTraveled[id] = dist;

            // Simple collision approximation: if we've gone beyond MAX_RANGE, explode
            if (dist >= MAX_RANGE)
            {
                ExplodeProjectile(id);
                continue;
            }

            // TODO: add proper traceline collision in next iteration
        }
    }

    // task continues automatically
}

// Utility: compute forward/right/up from angles (degrees) -> vectors
stock AngleVectors(const Float:angles[3], Float:forward[3], Float:right[3], Float:up[3])
{
    // angles are in degrees: angles[0]=pitch, angles[1]=yaw, angles[2]=roll
    new Float:radpitch = angles[0] * (3.14159265 / 180.0);
    new Float:radyaw   = angles[1] * (3.14159265 / 180.0);
    new Float:sr = floatcos(radpitch);
    new Float:sp = floatsin(radpitch);
    new Float:cy = floatcos(radyaw);
    new Float:sy = floatsin(radyaw);

    if (forward)
    {
        forward[0] = sr * cy; // cos(pitch)*cos(yaw) approximation
        forward[1] = sr * sy;
        forward[2] = -sp;
    }

    // right and up not needed for this stage
}

// Helpers for printing
stock server_print(const string[], {any,...})
{
    server_cmd(string, 0);
}

// Optional admin command to list smoke cores
public command_smokelist(id)
{
    if (!is_user_admin(id)) return 0;
    client_print(id, print_console, "[Smoke] Active Smoke Cores:");
    for (new i = 0; i < MAX_SMOKES; i++)
    {
        if (g_bSmokeActive[i])
        {
            client_print(id, print_console, "%d: (%.1f, %.1f, %.1f) owner=%d ent=%d", i, g_fSmokeOrigin[i][0], g_fSmokeOrigin[i][1], g_fSmokeOrigin[i][2], g_iSmokeOwner[i], g_iSmokeEntity[i]);
        }
    }
}
