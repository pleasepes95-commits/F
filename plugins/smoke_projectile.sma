/*
    plugins/smoke_projectile.sma
    Stage 1..3 - Projectile + Smoke Entity + 24 Sprite data per smoke

    Goals implemented in this file:
    - Projectile creation/movement/explosion (Phase 1)
    - Create a single smoke entity per explosion and a smoke_think (Phase 2)
    - Each smoke holds 24 "sprites" as DATA (no visible rendering yet) using a Fibonacci sphere distribution (Phase 3)
    - Expansion, Breathing (natural motion), Fade-in / Fade-out implemented inside the single smoke_think (Phase 4/5)
    - Cleanup of expired smokes and full memory clear (Phase 8 cleanup requirement)

    Performance notes:
    - Single thinker per smoke entity. No per-sprite Thinks.
    - Only active smokes are iterated in smoke_think. Sprite loops run only for active smokes.
    - Precompute base directions (Fibonacci sphere) at smoke creation to avoid expensive math every Tick.

    Usage:
    - bind "c" "+smoke" (press/hold/release)
    - plugin registers +smoke / -smoke commands

    Future phases will convert sprite DATA -> engine sprites/entities for rendering and AddToFullPack visibility handling.
*/

#define PLUGIN_NAME "smoke_projectile"
#define PLUGIN_VERSION "0.3"

#define MAX_PLAYERS 32
#define MAX_SMOKES 64
#define SPRITE_COUNT 24

// Projectile settings
#define PROJ_SPEED 900.0    // units per second
#define TASK_INTERVAL 0.02  // seconds per update (50 Hz)
#define MAX_RANGE 1400.0    // max travel distance before auto-explode

// Smoke core lifetime (data only)
#define SMOKE_LIFETIME 15.0 // seconds

// Smoke behavior defaults
#define DEFAULT_RADIUS_TARGET 200.0  // target radius units
#define DEFAULT_EXPAND_RATE 40.0     // units per second (approach rate)
#define DEFAULT_BREATHING_AMP 12.0   // units
#define DEFAULT_BREATHING_SPEED 1.8  // cycles per second
#define FADE_IN_TIME 0.5             // seconds
#define FADE_OUT_TIME 2.0            // last seconds to fade out

// Global projectile data (one projectile per player max)
new bool:g_bProjActive[MAX_PLAYERS+1];
new Float:g_fProjPos[MAX_PLAYERS+1][3];
new Float:g_fProjVel[MAX_PLAYERS+1][3];
new Float:g_fProjStartPos[MAX_PLAYERS+1][3];
new Float:g_fProjTraveled[MAX_PLAYERS+1];
new g_iProjTask = -1;

// Smoke core storage (data-only)
new bool:g_bSmokeActive[MAX_SMOKES];
new Float:g_fSmokeOrigin[MAX_SMOKES][3];
new Float:g_fSmokeCreateTime[MAX_SMOKES];
new Float:g_fSmokeExpireTime[MAX_SMOKES];
new g_iSmokeOwner[MAX_SMOKES];
new g_iSmokeEntity[MAX_SMOKES]; // entity index (info_target)

// Smoke runtime parameters
new Float:g_fSmokeRadiusCurrent[MAX_SMOKES];
new Float:g_fSmokeRadiusTarget[MAX_SMOKES];
new Float:g_fSmokeExpandRate[MAX_SMOKES];
new Float:g_fSmokeBreathingAmp[MAX_SMOKES];
new Float:g_fSmokeBreathingSpeed[MAX_SMOKES];

// Precomputed directions for sprites (Fibonacci sphere) per smoke
new Float:g_fSmokeDirs[MAX_SMOKES][SPRITE_COUNT][3];

// Sprite data per smoke (DATA ONLY). Each sprite has position offset, scale, alpha seeds
new Float:g_fSpritePos[MAX_SMOKES][SPRITE_COUNT][3];
new Float:g_fSpriteScale[MAX_SMOKES][SPRITE_COUNT];
new Float:g_fSpriteAlpha[MAX_SMOKES][SPRITE_COUNT];
new Float:g_fSpriteSeed[MAX_SMOKES][SPRITE_COUNT]; // small random per-sprite seed for noise

// Forward declarations
forward void:OnPlayerPressProj(id);
forward void:OnPlayerReleaseProj(id);
forward UpdateProjectiles();
forward CreateSmokeEntity(Float:ox, Float:oy, Float:oz, ownerid);
forward smoke_think(ent);
forward GenerateFibonacciDirs(slot, count);

public plugin_precache()
{
    // nothing to precache yet (no models/sounds)
}

public plugin_init()
{
    register_clcmd("+smoke", "OnPlayerPressProj");
    register_clcmd("-smoke", "OnPlayerReleaseProj");

    // start the global update task for projectiles
    g_iProjTask = set_task(TASK_INTERVAL, "UpdateProjectiles", _, _, _, "");

    // register the think name so engine can call our smoke_think when an entity thinks
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

    // cleanup any remaining smoke entities (defensive)
    for (new i = 0; i < MAX_SMOKES; i++)
    {
        if (g_bSmokeActive[i] && g_iSmokeEntity[i] > 0)
        {
            remove_entity(g_iSmokeEntity[i]);
            g_iSmokeEntity[i] = 0;
        }
        g_bSmokeActive[i] = false;
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
    client_print(id, print_console, "[Smoke] Exploded and spawned Smoke entity (data-only with 24 sprites).");

    return 1;
}

// Create a smoke entity (info_target with classname valorant_smoke) and initialize 24 sprite DATA entries
public CreateSmokeEntity(Float:ox, Float:oy, Float:oz, ownerid)
{
    // find free smoke slot
    new i;
    for (i = 0; i < MAX_SMOKES; i++)
    {
        if (!g_bSmokeActive[i]) break;
    }
    if (i >= MAX_SMOKES) {
        // recycle oldest (simple) - choose slot 0
        i = 0;
    }

    // store basic data
    g_bSmokeActive[i] = true;
    g_fSmokeOrigin[i][0] = ox;
    g_fSmokeOrigin[i][1] = oy;
    g_fSmokeOrigin[i][2] = oz;
    g_fSmokeCreateTime[i] = get_gametime();
    g_fSmokeExpireTime[i] = g_fSmokeCreateTime[i] + SMOKE_LIFETIME;
    g_iSmokeOwner[i] = ownerid;

    // runtime parameters (can be tuned later)
    g_fSmokeRadiusCurrent[i] = 8.0; // small initial radius
    g_fSmokeRadiusTarget[i] = DEFAULT_RADIUS_TARGET;
    g_fSmokeExpandRate[i] = DEFAULT_EXPAND_RATE;
    g_fSmokeBreathingAmp[i] = DEFAULT_BREATHING_AMP;
    g_fSmokeBreathingSpeed[i] = DEFAULT_BREATHING_SPEED;

    // Precompute 24 directions using Fibonacci sphere
    GenerateFibonacciDirs(i, SPRITE_COUNT);

    // initialize per-sprite seeds and baseline values (no engine sprites created yet)
    new Float:now = g_fSmokeCreateTime[i];
    for (new s = 0; s < SPRITE_COUNT; s++)
    {
        g_fSpriteSeed[i][s] = random_float(0.0, 6.2831853); // random phase
        g_fSpriteScale[i][s] = random_float(0.85, 1.20);
        g_fSpriteAlpha[i][s] = 0.0; // will be updated by fade-in
        // initial positions at origin
        g_fSpritePos[i][s][0] = ox;
        g_fSpritePos[i][s][1] = oy;
        g_fSpritePos[i][s][2] = oz;
    }

    // Create a lightweight entity as the single thinker for this smoke
    new ent = create_entity("info_target");
    if (ent <= 0)
    {
        server_print("[Smoke] Failed to create entity for smoke %d", i);
        // still keep data-only smoke but with no thinker - it will not update
        g_iSmokeEntity[i] = 0;
        return i;
    }

    entity_set_string(ent, EV_SZ_classname, "valorant_smoke");
    entity_set_origin(ent, ox, oy, oz);
    entity_set_float(ent, EV_FL_nextthink, get_gametime() + 0.05);

    g_iSmokeEntity[i] = ent;

    server_print("[Smoke] Initialized smoke slot %d with %d sprites at (%.1f, %.1f, %.1f)", i, SPRITE_COUNT, ox, oy, oz);

    return i;
}

// Fibonacci sphere: fill g_fSmokeDirs[slot][0..count-1][3]
public GenerateFibonacciDirs(slot, count)
{
    // golden angle
    new Float:phi = 3.14159265358979323846 * (3.0 - sqrt(5.0)); // ~2.399963

    if (count <= 0) return;

    for (new k = 0; k < count; k++)
    {
        new Float:idx = float(k);
        new Float:nm1 = float(count - 1);
        new Float:z = 1.0 - (2.0 * idx) / nm1; // z ranges from 1..-1
        new Float:r = floatsqrt(max_f(0.0, 1.0 - z*z));
        new Float:theta = phi * idx;
        new Float:x = r * floatcos(theta);
        new Float:y = r * floatsin(theta);

        // store normalized direction
        g_fSmokeDirs[slot][k][0] = x;
        g_fSmokeDirs[slot][k][1] = y;
        g_fSmokeDirs[slot][k][2] = z;
    }
}

// smoke_think: single thinker updating all sprite DATA for this entity's smoke slot
public smoke_think(ent)
{
    if (!is_valid_ent(ent))
    {
        return;
    }

    // find which slot corresponds to this entity
    new slot = -1;
    for (new i = 0; i < MAX_SMOKES; i++)
    {
        if (g_bSmokeActive[i] && g_iSmokeEntity[i] == ent)
        {
            slot = i;
            break;
        }
    }

    new Float:now = get_gametime();

    if (slot == -1)
    {
        // unknown entity - schedule nextthink and return
        entity_set_float(ent, EV_FL_nextthink, now + 0.05);
        return;
    }

    // Expiration check
    if (now >= g_fSmokeExpireTime[slot])
    {
        // cleanup data and remove entity
        remove_entity(ent);

        // clear data arrays for safety
        for (new s = 0; s < SPRITE_COUNT; s++)
        {
            g_fSpritePos[slot][s][0] = 0.0;
            g_fSpritePos[slot][s][1] = 0.0;
            g_fSpritePos[slot][s][2] = 0.0;
            g_fSpriteScale[slot][s] = 0.0;
            g_fSpriteAlpha[slot][s] = 0.0;
            g_fSpriteSeed[slot][s] = 0.0;
        }

        g_bSmokeActive[slot] = false;
        g_iSmokeEntity[slot] = 0;

        server_print("[Smoke] Slot %d expired and cleaned up.", slot);
        return;
    }

    // Compute progression and fade
    new Float:age = now - g_fSmokeCreateTime[slot];
    new Float:lifetime = g_fSmokeExpireTime[slot] - g_fSmokeCreateTime[slot];
    new Float:fadeFactor = 1.0;

    // Fade in
    if (age < FADE_IN_TIME)
    {
        fadeFactor = age / FADE_IN_TIME;
    }
    // Fade out
    else if (now > (g_fSmokeExpireTime[slot] - FADE_OUT_TIME))
    {
        new Float:remaining = g_fSmokeExpireTime[slot] - now;
        fadeFactor = max_f(0.0, remaining / FADE_OUT_TIME);
    }

    // Update expansion: approach target radius
    new Float:radiusNow = g_fSmokeRadiusCurrent[slot];
    new Float:target = g_fSmokeRadiusTarget[slot];
    new Float:rate = g_fSmokeExpandRate[slot];

    new Float:dt = 0.05; // match our nextthink interval (50ms)
    // approach: simple linear step toward target (stable and cheap)
    if (radiusNow < target)
    {
        radiusNow += rate * dt;
        if (radiusNow > target) radiusNow = target;
    }
    else if (radiusNow > target)
    {
        radiusNow -= rate * dt;
        if (radiusNow < target) radiusNow = target;
    }
    g_fSmokeRadiusCurrent[slot] = radiusNow;

    // Breathing (sinusoidal) - natural gas motion
    new Float:breathing = g_fSmokeBreathingAmp[slot] * floatsin((age * g_fSmokeBreathingSpeed[slot]) + 0.0);

    // Per-sprite update (DATA only). This loop runs only for active smoke slot.
    for (new s = 0; s < SPRITE_COUNT; s++)
    {
        // small deterministic noise using seed
        new Float:seed = g_fSpriteSeed[slot][s];
        new Float:noise = floatsin(seed + age * 1.3) * 3.0; // small jitter

        // final offset distance for this sprite
        new Float:dist = radiusNow + breathing + noise;

        // direction from precomputed dirs
        new Float:dx = g_fSmokeDirs[slot][s][0];
        new Float:dy = g_fSmokeDirs[slot][s][1];
        new Float:dz = g_fSmokeDirs[slot][s][2];

        // position = origin + dir * dist
        g_fSpritePos[slot][s][0] = g_fSmokeOrigin[slot][0] + dx * dist;
        g_fSpritePos[slot][s][1] = g_fSmokeOrigin[slot][1] + dy * dist;
        g_fSpritePos[slot][s][2] = g_fSmokeOrigin[slot][2] + dz * dist;

        // scale and alpha affected by fadeFactor and small random factor
        g_fSpriteScale[slot][s] = g_fSpriteScale[slot][s] * 0.0 + (0.5 * g_fSpriteScale[slot][s] + 0.5); // keep seed-based value while allowing future adjustments
        // For now set alpha as fadeFactor * base (base=0.9)
        g_fSpriteAlpha[slot][s] = 0.9 * fadeFactor;
    }

    // Reschedule next think (keep interval stable)
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

            // TODO: add proper traceline collision in next iteration (server-side trace_line)
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

// Debug command to print active smoke & first sprite positions
public command_smokelist(id)
{
    if (!is_user_admin(id)) return 0;
    client_print(id, print_console, "[Smoke] Active Smoke Cores and sample sprite positions:");
    for (new i = 0; i < MAX_SMOKES; i++)
    {
        if (g_bSmokeActive[i])
        {
            client_print(id, print_console, "%d: origin=(%.1f,%.1f,%.1f) age=%.1f slotEnt=%d", i, g_fSmokeOrigin[i][0], g_fSmokeOrigin[i][1], g_fSmokeOrigin[i][2], get_gametime()-g_fSmokeCreateTime[i], g_iSmokeEntity[i]);
            // print first 3 sprite positions as sample
            for (new s = 0; s < min(3, SPRITE_COUNT); s++)
            {
                client_print(id, print_console, "  sprite %d pos=(%.1f,%.1f,%.1f) alpha=%.2f scale=%.2f", s, g_fSpritePos[i][s][0], g_fSpritePos[i][s][1], g_fSpritePos[i][s][2], g_fSpriteAlpha[i][s], g_fSpriteScale[i][s]);
            }
        }
    }
}
