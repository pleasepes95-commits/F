/*
    plugins/smoke_projectile.sma
    AMX/Pawn plugin - add env_sprite rendering (initial 1 sprite per smoke)

    Changes in this version:
    - Create one env_sprite per smoke (placeholder model sprites/flare.spr)
    - Store sprite entity IDs and update their origins in smoke_think
    - Clean up sprite entities on expiration
    - Keep DATA for 24 sprite positions; currently we spawn 1 visible sprite to iterate quickly

    Next steps: increase visible sprites gradually (8,16,24), add per-sprite alpha/scale rendering, optimize update rates.
*/

#include <amxmodx>
#include <fakemeta>

#define PLUGIN_NAME "smoke_projectile"
#define PLUGIN_VERSION "0.6"

#define MAX_PLAYERS 32
#define MAX_SMOKES 64
#define SPRITE_COUNT 24

#define PROJ_SPEED 900.0
#define PROJ_TASK_INTERVAL 0.02
#define PROJ_MAX_RANGE 1400.0

#define SMOKE_LIFETIME 15.0
#define SMOKE_THINK_INTERVAL 0.05
#define FADE_IN_TIME 0.5
#define FADE_OUT_TIME 2.0

#define DEFAULT_RADIUS_TARGET 200.0
#define DEFAULT_EXPAND_RATE   40.0
#define DEFAULT_BREATH_AMP    12.0
#define DEFAULT_BREATH_SPEED  1.8

// Projectile data (one per player)
new bool:g_proj_active[MAX_PLAYERS+1];
new Float:g_proj_pos[MAX_PLAYERS+1][3];
new Float:g_proj_vel[MAX_PLAYERS+1][3];
new Float:g_proj_start[MAX_PLAYERS+1][3];
new Float:g_proj_travel[MAX_PLAYERS+1];
new g_proj_task = -1;

// Smoke data
new bool:g_smoke_active[MAX_SMOKES];
new Float:g_smoke_origin[MAX_SMOKES][3];
new Float:g_smoke_create[MAX_SMOKES];
new Float:g_smoke_expire[MAX_SMOKES];
new g_smoke_owner[MAX_SMOKES];
new g_smoke_entity[MAX_SMOKES];
new Float:g_smoke_lastthink[MAX_SMOKES];

new Float:g_smoke_radius_cur[MAX_SMOKES];
new Float:g_smoke_radius_target[MAX_SMOKES];
new Float:g_smoke_expand_rate[MAX_SMOKES];
new Float:g_smoke_breath_amp[MAX_SMOKES];
new Float:g_smoke_breath_speed[MAX_SMOKES];

// Fibonacci directions per smoke
new Float:g_smoke_dir[MAX_SMOKES][SPRITE_COUNT][3];

// Sprite DATA per smoke (no engine sprites yet)
new Float:g_sprite_pos[MAX_SMOKES][SPRITE_COUNT][3];
new Float:g_sprite_scale[MAX_SMOKES][SPRITE_COUNT];
new Float:g_sprite_alpha[MAX_SMOKES][SPRITE_COUNT];
new Float:g_sprite_seed[MAX_SMOKES][SPRITE_COUNT];

// Visible sprite entities (env_sprite)
new g_smoke_sprite_ent[MAX_SMOKES][SPRITE_COUNT];
new g_smoke_sprite_count[MAX_SMOKES]; // how many visible sprites currently spawned (we start with 1)

// Forwards
forward OnPlayerPress(id);
forward OnPlayerRelease(id);
forward UpdateProjectiles();
forward CreateSmokeAt(Float:ox, Float:oy, Float:oz, owner);
forward smoke_think(ent);
forward GenerateFibonacci(slot, count);

// Helpers
stock Float:RandomFloat(Float:lo, Float:hi)
{
    return random_float(lo, hi);
}

stock Float:Clamp(Float:v, Float:lo, Float:hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

public plugin_init()
{
    register_clcmd("+smoke", "OnPlayerPress");
    register_clcmd("-smoke", "OnPlayerRelease");

    g_proj_task = set_task(PROJ_TASK_INTERVAL, "UpdateProjectiles", _, _, _, "");

    // register thinker name (best-effort; some builds require it)
    register_think("valorant_smoke", "smoke_think");

    log_event(true, PLUGIN_NAME " v" PLUGIN_VERSION " loaded.");
}

public plugin_end()
{
    if (g_proj_task != -1)
    {
        kill_task(g_proj_task);
        g_proj_task = -1;
    }

    // defensive cleanup
    for (new i = 0; i < MAX_SMOKES; i++)
    {
        if (g_smoke_active[i])
        {
            // remove visible sprite entities
            new cnt = g_smoke_sprite_count[i];
            for (new s = 0; s < cnt; s++) if (g_smoke_sprite_ent[i][s] > 0) { remove_entity(g_smoke_sprite_ent[i][s]); g_smoke_sprite_ent[i][s] = 0; }

            if (g_smoke_entity[i] > 0) { remove_entity(g_smoke_entity[i]); g_smoke_entity[i] = 0; }
        }
        g_smoke_active[i] = false;
    }
}

public client_disconnect(id)
{
    if (g_proj_active[id])
    {
        ExplodeProjectile(id);
    }
}

// Player input handlers
public OnPlayerPress(id)
{
    if (!is_user_connected(id) || !is_user_alive(id)) return;
    if (g_proj_active[id]) return;

    new Float:origin[3];
    new Float:angles[3];

    pev(id, pev_v_origin, origin);
    pev(id, pev_v_angle, angles);

    new Float:forward[3];
    angle_vector(forward, angles);

    g_proj_pos[id][0] = origin[0] + forward[0]*18.0;
    g_proj_pos[id][1] = origin[1] + forward[1]*18.0;
    g_proj_pos[id][2] = origin[2] + forward[2]*18.0 + 10.0;

    g_proj_vel[id][0] = forward[0] * PROJ_SPEED;
    g_proj_vel[id][1] = forward[1] * PROJ_SPEED;
    g_proj_vel[id][2] = forward[2] * PROJ_SPEED;

    g_proj_start[id][0] = g_proj_pos[id][0];
    g_proj_start[id][1] = g_proj_pos[id][1];
    g_proj_start[id][2] = g_proj_pos[id][2];

    g_proj_travel[id] = 0.0;
    g_proj_active[id] = true;

    client_print(id, print_console, "[smoke] Projectile created. Release to deploy.");
}

public OnPlayerRelease(id)
{
    if (!is_user_connected(id)) return;
    if (!g_proj_active[id]) return;

    ExplodeProjectile(id);
}

public ExplodeProjectile(id)
{
    if (!g_proj_active[id]) return 0;

    new Float:ox = g_proj_pos[id][0];
    new Float:oy = g_proj_pos[id][1];
    new Float:oz = g_proj_pos[id][2];

    CreateSmokeAt(ox, oy, oz, id);

    g_proj_active[id] = false;
    g_proj_travel[id] = 0.0;

    client_print(id, print_console, "[smoke] Exploded and spawned smoke entity.");
    return 1;
}

// Create smoke data and thinker entity (and spawn initial visible env_sprite)
public CreateSmokeAt(Float:ox, Float:oy, Float:oz, owner)
{
    new slot = -1;
    for (new i = 0; i < MAX_SMOKES; i++) if (!g_smoke_active[i]) { slot = i; break; }
    if (slot == -1) slot = 0; // recycle

    g_smoke_active[slot] = true;
    g_smoke_origin[slot][0] = ox;
    g_smoke_origin[slot][1] = oy;
    g_smoke_origin[slot][2] = oz;
    g_smoke_create[slot] = get_gametime();
    g_smoke_expire[slot] = g_smoke_create[slot] + SMOKE_LIFETIME;
    g_smoke_owner[slot] = owner;
    g_smoke_entity[slot] = 0;
    g_smoke_lastthink[slot] = g_smoke_create[slot];

    g_smoke_radius_cur[slot] = 8.0;
    g_smoke_radius_target[slot] = DEFAULT_RADIUS_TARGET;
    g_smoke_expand_rate[slot] = DEFAULT_EXPAND_RATE;
    g_smoke_breath_amp[slot] = DEFAULT_BREATH_AMP;
    g_smoke_breath_speed[slot] = DEFAULT_BREATH_SPEED;

    // precompute directions
    GenerateFibonacci(slot, SPRITE_COUNT);

    // init sprite data
    for (new s = 0; s < SPRITE_COUNT; s++)
    {
        g_sprite_seed[slot][s] = RandomFloat(0.0, 6.2831853);
        g_sprite_scale[slot][s] = RandomFloat(0.9, 1.15);
        g_sprite_alpha[slot][s] = 0.0;
        g_sprite_pos[slot][s][0] = ox;
        g_sprite_pos[slot][s][1] = oy;
        g_sprite_pos[slot][s][2] = oz;
        g_smoke_sprite_ent[slot][s] = 0; // clear any previous
    }

    // spawn single env_sprite as visible test
    new entSprite = create_entity("env_sprite");
    if (entSprite > 0)
    {
        // model - placeholder (changeable)
        entity_set_string(entSprite, EV_SZ_model, "sprites/flare.spr");
        new Float:spos[3]; spos[0] = ox; spos[1] = oy; spos[2] = oz;
        entity_set_origin(entSprite, spos);

        // store
        g_smoke_sprite_ent[slot][0] = entSprite;
        g_smoke_sprite_count[slot] = 1;
    }
    else
    {
        g_smoke_sprite_count[slot] = 0; // no visible sprites
    }

    // create thinker entity
    new ent = create_entity("info_target");
    if (ent <= 0)
    {
        server_print("[smoke] Failed to create thinker entity for slot %d", slot);
        g_smoke_entity[slot] = 0;
        return slot;
    }

    entity_set_string(ent, EV_SZ_classname, "valorant_smoke");
    new Float:entOrigin[3]; entOrigin[0] = ox; entOrigin[1] = oy; entOrigin[2] = oz;
    entity_set_origin(ent, entOrigin);
    entity_set_float(ent, EV_FL_nextthink, get_gametime() + SMOKE_THINK_INTERVAL);
    g_smoke_entity[slot] = ent;

    server_print("[smoke] Spawned smoke slot %d at (%.1f, %.1f, %.1f) with %d visible sprites", slot, ox, oy, oz, g_smoke_sprite_count[slot]);
    return slot;
}

// Fibonacci sphere generators
public GenerateFibonacci(slot, count)
{
    new Float:phi = 2.399963229728653; // golden angle
    if (count <= 0) return;

    new Float:den = float(max(1, count - 1));
    for (new k = 0; k < count; k++)
    {
        new Float:idx = float(k);
        new Float:z = 1.0 - (2.0 * idx) / den;
        new Float:r = floatsqroot(max_f(0.0, 1.0 - z*z));
        new Float:theta = phi * idx;
        new Float:x = r * floatcos(theta);
        new Float:y = r * floatsin(theta);
        g_smoke_dir[slot][k][0] = x;
        g_smoke_dir[slot][k][1] = y;
        g_smoke_dir[slot][k][2] = z;
    }
}

// smoke_think: updates sprite DATA and visible env_sprite origins
public smoke_think(ent)
{
    if (!is_valid_ent(ent)) return;

    new slot = -1;
    for (new i = 0; i < MAX_SMOKES; i++) if (g_smoke_active[i] && g_smoke_entity[i] == ent) { slot = i; break; }

    new Float:now = get_gametime();
    if (slot == -1)
    {
        entity_set_float(ent, EV_FL_nextthink, now + SMOKE_THINK_INTERVAL);
        return;
    }

    if (now >= g_smoke_expire[slot])
    {
        // remove visible sprites
        new cnt = g_smoke_sprite_count[slot];
        for (new s = 0; s < cnt; s++) if (g_smoke_sprite_ent[slot][s] > 0) { remove_entity(g_smoke_sprite_ent[slot][s]); g_smoke_sprite_ent[slot][s] = 0; }

        // remove thinker
        remove_entity(ent);
        for (new s = 0; s < SPRITE_COUNT; s++)
        {
            g_sprite_pos[slot][s][0] = 0.0;
            g_sprite_pos[slot][s][1] = 0.0;
            g_sprite_pos[slot][s][2] = 0.0;
            g_sprite_scale[slot][s] = 0.0;
            g_sprite_alpha[slot][s] = 0.0;
            g_sprite_seed[slot][s] = 0.0;
        }
        g_smoke_active[slot] = false;
        g_smoke_entity[slot] = 0;
        g_smoke_sprite_count[slot] = 0;
        server_print("[smoke] Slot %d expired and cleaned.", slot);
        return;
    }

    new Float:dt = now - g_smoke_lastthink[slot];
    if (dt <= 0.0) dt = SMOKE_THINK_INTERVAL;
    g_smoke_lastthink[slot] = now;

    new Float:age = now - g_smoke_create[slot];
    new Float:fade = 1.0;
    if (age < FADE_IN_TIME) { fade = Clamp(age / FADE_IN_TIME, 0.0, 1.0); }
    else if (now > (g_smoke_expire[slot] - FADE_OUT_TIME)) { new Float:rem = g_smoke_expire[slot] - now; fade = Clamp(rem / FADE_OUT_TIME, 0.0, 1.0); }

    new Float:cur = g_smoke_radius_cur[slot];
    new Float:target = g_smoke_radius_target[slot];
    new Float:rate = g_smoke_expand_rate[slot];
    if (cur < target) { cur += rate * dt; if (cur > target) cur = target; }
    else if (cur > target) { cur -= rate * dt; if (cur < target) cur = target; }
    g_smoke_radius_cur[slot] = cur;

    new Float:breath = g_smoke_breath_amp[slot] * floatsin(age * g_smoke_breath_speed[slot]);

    // update sprite DATA
    for (new s = 0; s < SPRITE_COUNT; s++)
    {
        new Float:seed = g_sprite_seed[slot][s];
        new Float:noise = floatsin(seed + age * 1.3) * 3.0;
        new Float:dist = cur + breath + noise;

        new Float:dx = g_smoke_dir[slot][s][0];
        new Float:dy = g_smoke_dir[slot][s][1];
        new Float:dz = g_smoke_dir[slot][s][2];

        g_sprite_pos[slot][s][0] = g_smoke_origin[slot][0] + dx * dist;
        g_sprite_pos[slot][s][1] = g_smoke_origin[slot][1] + dy * dist;
        g_sprite_pos[slot][s][2] = g_smoke_origin[slot][2] + dz * dist;

        g_sprite_alpha[slot][s] = 0.9 * fade;
    }

    // update visible env_sprite entities (only for spawned count)
    new cnt = g_smoke_sprite_count[slot];
    for (new s = 0; s < cnt; s++)
    {
        new entSpr = g_smoke_sprite_ent[slot][s];
        if (entSpr <= 0) continue;
        new Float:pos[3]; pos[0] = g_sprite_pos[slot][s][0]; pos[1] = g_sprite_pos[slot][s][1]; pos[2] = g_sprite_pos[slot][s][2];
        entity_set_origin(entSpr, pos);
        // note: setting alpha/scale on env_sprite may require different keyvalues; left for next iteration
    }

    entity_set_float(ent, EV_FL_nextthink, now + SMOKE_THINK_INTERVAL);
}

// UpdateProjectiles - global task
public UpdateProjectiles()
{
    new Float:dt = PROJ_TASK_INTERVAL;

    for (new id = 1; id <= get_maxplayers(); id++)
    {
        if (!is_user_connected(id)) continue;
        if (!g_proj_active[id]) continue;

        if (is_user_alive(id))
        {
            new Float:angles[3];
            pev(id, pev_v_angle, angles);
            new Float:forward[3];
            angle_vector(forward, angles);
            g_proj_vel[id][0] = forward[0] * PROJ_SPEED;
            g_proj_vel[id][1] = forward[1] * PROJ_SPEED;
            g_proj_vel[id][2] = forward[2] * PROJ_SPEED;
        }

        g_proj_pos[id][0] += g_proj_vel[id][0] * dt;
        g_proj_pos[id][1] += g_proj_vel[id][1] * dt;
        g_proj_pos[id][2] += g_proj_vel[id][2] * dt;

        new Float:dx = g_proj_pos[id][0] - g_proj_start[id][0];
        new Float:dy = g_proj_pos[id][1] - g_proj_start[id][1];
        new Float:dz = g_proj_pos[id][2] - g_proj_start[id][2];

        new Float:dist = floatsqroot(dx*dx + dy*dy + dz*dz);
        g_proj_travel[id] = dist;

        if (dist >= PROJ_MAX_RANGE) { ExplodeProjectile(id); continue; }
    }
}

// Admin debug
public command_smokelist(id)
{
    if (!is_user_admin(id)) return 0;
    client_print(id, print_console, "[smoke] Active slots:");
    for (new i = 0; i < MAX_SMOKES; i++)
    {
        if (g_smoke_active[i])
        {
            client_print(id, print_console, "%d: origin=(%.1f,%.1f,%.1f) age=%.1f ent=%d",
                i, g_smoke_origin[i][0], g_smoke_origin[i][1], g_smoke_origin[i][2], get_gametime()-g_smoke_create[i], g_smoke_entity[i]);
            client_print(id, print_console, "  sprite0 pos=(%.1f,%.1f,%.1f) alpha=%.2f",
                g_sprite_pos[i][0][0], g_sprite_pos[i][0][1], g_sprite_pos[i][0][2], g_sprite_alpha[i][0]);
        }
    }
    return 1;
}
