------------------------------------------------------------
-- moving_nodes : véhicule + structure collée + collisions --
-- + sélection volume + preview particules + blueprints     --
-- + mouvement fluide (accel/friction + glissement)         --
------------------------------------------------------------

-------------------------
-- Etat global (simple) --
-------------------------

local builder = {
    nodes = {},    -- positions absolues des nodes choisis (vector)
    origin = nil,  -- position absolue (vector) : référence
}

local current_vehicle = nil

-------------------------
-- Mod storage (plans) --
-------------------------

local storage = minetest.get_mod_storage()
local blueprints = {}
do
    local raw = storage:get_string("moving_nodes_blueprints")
    if raw and raw ~= "" then
        local t = minetest.deserialize(raw)
        if type(t) == "table" then
            blueprints = t
        end
    end
end

local function save_blueprints()
    storage:set_string("moving_nodes_blueprints", minetest.serialize(blueprints))
end

-------------------------
-- Helpers
-------------------------

local function builder_clear()
    builder.nodes = {}
    builder.origin = nil
end

local function pos_equal(a, b)
    return a.x == b.x and a.y == b.y and a.z == b.z
end

local function world_pos_from_origin(origin, offset)
    -- Convertit origin (float) + offset (int) en pos monde (int)
    return {
        x = math.floor(origin.x + offset.x + 0.5),
        y = math.floor(origin.y + offset.y + 0.5),
        z = math.floor(origin.z + offset.z + 0.5),
    }
end

local function minmax(a, b)
    return math.min(a, b), math.max(a, b)
end

local function get_box(p1, p2)
    local x1, x2 = minmax(p1.x, p2.x)
    local y1, y2 = minmax(p1.y, p2.y)
    local z1, z2 = minmax(p1.z, p2.z)
    return x1, y1, z1, x2, y2, z2
end

local function volume_size(p1, p2)
    local x1, y1, z1, x2, y2, z2 = get_box(p1, p2)
    return (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)
end

local function get_pointed_node_pos(player, range)
    range = range or 10
    local pos = player:get_pos()
    if not pos then return nil end

    local props = player:get_properties() or {}
    local eye = vector.new(pos)
    eye.y = eye.y + (props.eye_height or 1.47)

    local dir = player:get_look_dir()
    if not dir then return nil end

    local to = vector.add(eye, vector.multiply(dir, range))
    local ray = minetest.raycast(eye, to, false, false)
    for pointed in ray do
        if pointed.type == "node" then
            return pointed.under
        end
    end
    return nil
end

-------------------------
-- Sélection volume + preview
-------------------------

local selections = {} -- selections[playername] = {pos1=..., pos2=...}

local function set_sel(name, which, pos)
    selections[name] = selections[name] or {}
    selections[name][which] = vector.round(pos)
end

local function get_sel(name)
    local s = selections[name]
    if not s or not s.pos1 or not s.pos2 then return nil end
    return s.pos1, s.pos2
end

-- Preview particules (coins + contour)
local PREVIEW_INTERVAL = 0.25
local PREVIEW_LIFETIME = 0.35
local PREVIEW_MAX_POINTS = 1200
local PREVIEW_STEP = 1

local function add_particle(playername, pos, size)
    minetest.add_particle({
        pos = {x = pos.x + 0.5, y = pos.y + 0.5, z = pos.z + 0.5},
        velocity = {x = 0, y = 0, z = 0},
        acceleration = {x = 0, y = 0, z = 0},
        expirationtime = PREVIEW_LIFETIME,
        size = size or 6,
        collisiondetection = false,
        collision_removal = false,
        object_collision = false,
        vertical = false,
        texture = "default_mese_crystal_fragment.png",
        glow = 10,
        playername = playername, -- visible seulement pour ce joueur (si supporté)
    })
end

local function add_edge_points(playername, a, b, step)
    step = step or PREVIEW_STEP
    local dx = b.x - a.x
    local dy = b.y - a.y
    local dz = b.z - a.z
    local n = math.max(math.abs(dx), math.abs(dy), math.abs(dz))
    if n == 0 then
        add_particle(playername, a, 3)
        return 1
    end

    local count = 0
    for i = 0, n, step do
        local t = i / n
        local p = {
            x = math.floor(a.x + dx * t + 0.5),
            y = math.floor(a.y + dy * t + 0.5),
            z = math.floor(a.z + dz * t + 0.5),
        }
        add_particle(playername, p, 2)
        count = count + 1
        if count >= PREVIEW_MAX_POINTS then break end
    end
    return count
end

local function show_selection_preview(playername, p1, p2)
    local x1, y1, z1, x2, y2, z2 = get_box(p1, p2)

    local c000 = {x=x1, y=y1, z=z1}
    local c100 = {x=x2, y=y1, z=z1}
    local c010 = {x=x1, y=y2, z=z1}
    local c110 = {x=x2, y=y2, z=z1}
    local c001 = {x=x1, y=y1, z=z2}
    local c101 = {x=x2, y=y1, z=z2}
    local c011 = {x=x1, y=y2, z=z2}
    local c111 = {x=x2, y=y2, z=z2}

    add_particle(playername, c000, 8)
    add_particle(playername, c100, 8)
    add_particle(playername, c010, 8)
    add_particle(playername, c110, 8)
    add_particle(playername, c001, 8)
    add_particle(playername, c101, 8)
    add_particle(playername, c011, 8)
    add_particle(playername, c111, 8)

    add_edge_points(playername, c000, c100)
    add_edge_points(playername, c000, c010)
    add_edge_points(playername, c000, c001)

    add_edge_points(playername, c111, c101)
    add_edge_points(playername, c111, c110)
    add_edge_points(playername, c111, c011)

    add_edge_points(playername, c001, c101)
    add_edge_points(playername, c001, c011)

    add_edge_points(playername, c010, c110)
    add_edge_points(playername, c010, c011)

    add_edge_points(playername, c100, c110)
    add_edge_points(playername, c100, c101)
end

local preview_timer = 0
minetest.register_globalstep(function(dtime)
    preview_timer = preview_timer + dtime
    if preview_timer < PREVIEW_INTERVAL then return end
    preview_timer = 0

    for playername, sel in pairs(selections) do
        if sel and sel.pos1 and sel.pos2 then
            local player = minetest.get_player_by_name(playername)
            if player then
                show_selection_preview(playername, sel.pos1, sel.pos2)
            end
        end
    end
end)

-------------------------
-- OUTIL : glue
-------------------------

minetest.register_tool("moving_nodes:glue", {
    description = "Outil de colle (coller/décoller des nodes dans la structure)",
    inventory_image = "moving_nodes_glue.png",
    wield_image = "moving_nodes_glue.png",

    on_use = function(itemstack, user, pointed_thing)
        local name = user:get_player_name()

        if current_vehicle then
            minetest.chat_send_player(name, "[moving_nodes] Un véhicule existe déjà. /moving_nodes_reset avant de modifier la structure.")
            return itemstack
        end

        if pointed_thing.type ~= "node" then
            return itemstack
        end

        local pos = pointed_thing.under

        for i, p in ipairs(builder.nodes) do
            if pos_equal(p, pos) then
                table.remove(builder.nodes, i)

                if #builder.nodes == 0 then
                    builder.origin = nil
                    minetest.chat_send_player(name, "[moving_nodes] Structure vide.")
                else
                    if builder.origin and pos_equal(builder.origin, pos) then
                        builder.origin = vector.new(builder.nodes[1])
                    end
                    minetest.chat_send_player(name, "[moving_nodes] Node retiré de la structure.")
                end
                return itemstack
            end
        end

        local node = minetest.get_node(pos)
        if node.name == "air" then
            minetest.chat_send_player(name, "[moving_nodes] Impossible de coller l'air.")
            return itemstack
        end

        table.insert(builder.nodes, vector.new(pos))
        if not builder.origin then
            builder.origin = vector.new(pos)
        end

        minetest.chat_send_player(name, "[moving_nodes] Node ajouté. Total: " .. #builder.nodes)
        return itemstack
    end,
})

------------------------------------------------------------
-- Commandes sélection volume
------------------------------------------------------------

minetest.register_chatcommand("moving_nodes_pos1", {
    params = "[point]",
    description = "Définit le coin 1 (sans arg = position joueur, avec 'point' = node visé)",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "[moving_nodes] Joueur introuvable." end

        local pos
        if param == "point" then
            pos = get_pointed_node_pos(player)
            if not pos then return false, "[moving_nodes] Aucun node visé." end
        else
            pos = player:get_pos()
        end

        set_sel(name, "pos1", pos)
        local p1 = selections[name].pos1
        return true, ("[moving_nodes] pos1 = %d,%d,%d"):format(p1.x, p1.y, p1.z)
    end,
})

minetest.register_chatcommand("moving_nodes_pos2", {
    params = "[point]",
    description = "Définit le coin 2 (sans arg = position joueur, avec 'point' = node visé)",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "[moving_nodes] Joueur introuvable." end

        local pos
        if param == "point" then
            pos = get_pointed_node_pos(player)
            if not pos then return false, "[moving_nodes] Aucun node visé." end
        else
            pos = player:get_pos()
        end

        set_sel(name, "pos2", pos)
        local p2 = selections[name].pos2
        return true, ("[moving_nodes] pos2 = %d,%d,%d"):format(p2.x, p2.y, p2.z)
    end,
})

minetest.register_chatcommand("moving_nodes_selclear", {
    description = "Efface pos1/pos2 pour toi",
    func = function(name, param)
        selections[name] = nil
        return true, "[moving_nodes] Sélection effacée."
    end,
})

minetest.register_chatcommand("moving_nodes_fill", {
    description = "Colle tous les nodes (non-air) dans le volume pos1-pos2",
    func = function(name, param)
        if current_vehicle then
            return false, "[moving_nodes] Un véhicule existe déjà. /moving_nodes_reset avant."
        end

        local p1, p2 = get_sel(name)
        if not p1 or not p2 then
            return false, "[moving_nodes] Définis pos1/pos2 avec /moving_nodes_pos1 et /moving_nodes_pos2."
        end

        local max_nodes = 20000
        local total = volume_size(p1, p2)
        if total > max_nodes then
            return false, ("[moving_nodes] Volume trop grand (%d). Limite=%d"):format(total, max_nodes)
        end

        builder_clear()

        local x1, y1, z1, x2, y2, z2 = get_box(p1, p2)
        builder.origin = {x = x1, y = y1, z = z1}

        local count = 0
        for z = z1, z2 do
            for y = y1, y2 do
                for x = x1, x2 do
                    local pos = {x = x, y = y, z = z}
                    local node = minetest.get_node(pos)
                    if node and node.name and node.name ~= "air" and node.name ~= "ignore" then
                        table.insert(builder.nodes, vector.new(pos))
                        count = count + 1
                    end
                end
            end
        end

        if count == 0 then
            builder_clear()
            return true, "[moving_nodes] Aucun node non-air dans le volume."
        end

        return true, ("[moving_nodes] %d nodes collés depuis le volume. Origine=%d,%d,%d"):format(
            count, builder.origin.x, builder.origin.y, builder.origin.z
        )
    end,
})

------------------------------------------------------------
-- Structure portée par le véhicule (offsets + nodes)
------------------------------------------------------------

local function copy_structure_from_builder(self)
    if not builder.origin or #builder.nodes == 0 then
        self.structure = nil
        return
    end

    local origin = vector.new(builder.origin)
    local offsets = {}
    local nodes = {}

    for i, abs_pos in ipairs(builder.nodes) do
        local off = vector.subtract(abs_pos, origin)
        offsets[i] = { x = off.x, y = off.y, z = off.z }

        local nd = minetest.get_node(abs_pos)
        nodes[i] = { name = nd.name, param2 = nd.param2 or 0 }
    end

    self.structure = { origin = origin, offsets = offsets, nodes = nodes }
end

local function can_move_structure(structure, delta)
    if not structure or not structure.origin or not structure.offsets then
        return false
    end

    local current_index = {}
    for _, off in ipairs(structure.offsets) do
        local p = world_pos_from_origin(structure.origin, off)
        current_index[minetest.pos_to_string(p)] = true
    end

    local new_origin = vector.add(structure.origin, delta)

    for _, off in ipairs(structure.offsets) do
        local dest = world_pos_from_origin(new_origin, off)
        local key = minetest.pos_to_string(dest)

        if not current_index[key] then
            local node = minetest.get_node(dest)
            local def = minetest.registered_nodes[node.name]
            if node.name ~= "air" and node.name ~= "ignore" then
                if not def or def.walkable then
                    return false
                end
            end
        end
    end
    return true
end

local function move_structure(structure, delta)
    if not structure or not structure.origin or not structure.offsets or not structure.nodes then
        return
    end

    local old_origin = vector.new(structure.origin)
    local new_origin = vector.add(structure.origin, delta)

    local old_positions = {}
    local new_positions = {}
    local changed = false

    for i, off in ipairs(structure.offsets) do
        local old_pos = world_pos_from_origin(old_origin, off)
        local new_pos = world_pos_from_origin(new_origin, off)
        old_positions[i] = old_pos
        new_positions[i] = new_pos
        if not pos_equal(old_pos, new_pos) then
            changed = true
        end
    end

    if not changed then
        structure.origin = new_origin
        return
    end

    for _, p in ipairs(old_positions) do
        minetest.remove_node(p)
    end

    for i, p in ipairs(new_positions) do
        local nd = structure.nodes[i]
        if nd and nd.name and nd.name ~= "air" then
            minetest.set_node(p, { name = nd.name, param2 = nd.param2 or 0 })
        end
    end

    structure.origin = new_origin
end

------------------------------------------------------------
-- ENTITÉ VÉHICULE (invisible) + mouvement fluide
------------------------------------------------------------

minetest.register_entity("moving_nodes:vehicle", {
    initial_properties = {
        physical = true,
        collide_with_objects = true,
        collisionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
        selectionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
        visual = "cube",
        visual_size = {x = 1, y = 1},
        textures = {"blank.png","blank.png","blank.png","blank.png","blank.png","blank.png"},
        static_save = true,
    },

    driver_name = nil,
    driver_offset = nil, -- position relative (float) du joueur
    old_physics = nil,
    structure = nil,

    -- Mouvement fluide
    vel = {x=0, y=0, z=0},
    accel = 18,
    friction = 10,
    max_speed = 6,   -- horiz (blocs/s)
    max_vspeed = 4,  -- vertical (blocs/s)

    on_activate = function(self, staticdata, dtime_s)
        if staticdata and staticdata ~= "" then
            local data = minetest.deserialize(staticdata)
            if data and data.structure then
                self.structure = data.structure
            end
        end
        -- S’assurer que vel existe
        self.vel = self.vel or {x=0,y=0,z=0}
    end,

    get_staticdata = function(self)
        return minetest.serialize({ structure = self.structure })
    end,

    on_step = function(self, dtime)
        if not self.structure or not self.structure.origin or not self.structure.offsets
            or #self.structure.offsets == 0 then
            return
        end

        local driver = self.driver_name and minetest.get_player_by_name(self.driver_name)
        if not driver then
            self.driver_name = nil
            self.driver_offset = nil
            self.old_physics = nil
            -- amortir progressivement
            self.vel.x, self.vel.y, self.vel.z = 0, 0, 0
            return
        end

        local ctrl = driver:get_player_control()
        if not ctrl then return end

        local yaw = driver:get_look_horizontal() or 0
        self.object:set_yaw(yaw)

        local forward = { x = -math.sin(yaw), y = 0, z = math.cos(yaw) }
        local right   = { x = forward.z,      y = 0, z = -forward.x }

        local dir = {x = 0, y = 0, z = 0}

        if ctrl.up then
            dir.x = dir.x + forward.x
            dir.z = dir.z + forward.z
        end
        if ctrl.down then
            dir.x = dir.x - forward.x
            dir.z = dir.z - forward.z
        end
        if ctrl.left then
            dir.x = dir.x - right.x
            dir.z = dir.z - right.z
        end
        if ctrl.right then
            dir.x = dir.x + right.x
            dir.z = dir.z + right.z
        end

        -- vertical : jump/sneak
        if ctrl.jump then dir.y = dir.y + self.max_vspeed end
        if ctrl.sneak then dir.y = dir.y - self.max_vspeed end

        -- normalisation horizontale
        local horiz_len = math.sqrt(dir.x * dir.x + dir.z * dir.z)
        if horiz_len > 0 then
            dir.x = dir.x / horiz_len
            dir.z = dir.z / horiz_len
        end

        -- vitesse désirée
        local desired = {
            x = dir.x * self.max_speed,
            y = dir.y, -- déjà en blocs/s
            z = dir.z * self.max_speed,
        }

        local function approach(cur, target, rate, dt)
            local diff = target - cur
            local step = rate * dt
            if diff > step then return cur + step end
            if diff < -step then return cur - step end
            return target
        end

        local ax = (math.abs(desired.x) > 0.001) and self.accel or self.friction
        local az = (math.abs(desired.z) > 0.001) and self.accel or self.friction
        local ay = (math.abs(desired.y) > 0.001) and self.accel or self.friction

        self.vel.x = approach(self.vel.x, desired.x, ax, dtime)
        self.vel.y = approach(self.vel.y, desired.y, ay, dtime)
        self.vel.z = approach(self.vel.z, desired.z, az, dtime)

        local delta = {
            x = self.vel.x * dtime,
            y = self.vel.y * dtime,
            z = self.vel.z * dtime,
        }

        -- arrondi léger
        local function round2(v) return math.floor(v * 100 + 0.5) / 100 end
        delta.x, delta.y, delta.z = round2(delta.x), round2(delta.y), round2(delta.z)

        -- Collisions + glissement sur les murs (axes séparés)
        local function try_move_axis(d)
            if (d.x == 0 and d.y == 0 and d.z == 0) then return false end
            if can_move_structure(self.structure, d) then
                move_structure(self.structure, d)
                return true
            end
            return false
        end

        if not can_move_structure(self.structure, delta) then
            local moved = false

            -- X
            if delta.x ~= 0 then
                if try_move_axis({x=delta.x, y=0, z=0}) then
                    moved = true
                else
                    self.vel.x = 0
                end
            end
            -- Y
            if delta.y ~= 0 then
                if try_move_axis({x=0, y=delta.y, z=0}) then
                    moved = true
                else
                    self.vel.y = 0
                end
            end
            -- Z
            if delta.z ~= 0 then
                if try_move_axis({x=0, y=0, z=delta.z}) then
                    moved = true
                else
                    self.vel.z = 0
                end
            end

            -- si rien n'a bougé : stop complet
            if not moved then
                self.vel.x, self.vel.y, self.vel.z = 0, 0, 0
            end
        else
            move_structure(self.structure, delta)
        end

        -- Entité en FLOAT (fluide)
        self.object:set_pos(self.structure.origin)

        -- Maintenir conducteur précisément, sans casser l’interpolation
        if self.driver_offset then
            local target = vector.add(self.structure.origin, self.driver_offset)
            local p = driver:get_pos()
            if (not p) or vector.distance(p, target) > 0.05 then
                driver:set_pos(target)
            end
        end
    end,
})

------------------------------------------------------------
-- OUTIL : harnais (créer/monter/descendre) - position exacte
------------------------------------------------------------

minetest.register_tool("moving_nodes:harness", {
    description = "Outil d'attache au véhicule (position exacte)",
    inventory_image = "moving_nodes_harness.png",
    wield_image = "moving_nodes_harness.png",

    on_use = function(itemstack, user, pointed_thing)
        local name = user:get_player_name()
        local player_pos = user:get_pos()

        if current_vehicle then
            local ent = current_vehicle:get_luaentity()
            if not ent or not ent.structure or not ent.structure.origin then
                current_vehicle = nil
                return itemstack
            end

            -- descendre
            if ent.driver_name == name then
                ent.driver_name = nil
                ent.driver_offset = nil

                if ent.old_physics then
                    user:set_physics_override(ent.old_physics)
                    ent.old_physics = nil
                end

                minetest.chat_send_player(name, "[moving_nodes] Tu quittes le véhicule.")
                return itemstack
            end

            -- monter
            if not ent.driver_name then
                ent.driver_name = name

                ent.old_physics = user:get_physics_override()
                user:set_physics_override({speed = 0, jump = 0})

                ent.driver_offset = vector.subtract(player_pos, ent.structure.origin)

                minetest.chat_send_player(name, "[moving_nodes] Tu montes dans le véhicule.")
                return itemstack
            else
                minetest.chat_send_player(name, "[moving_nodes] Véhicule déjà conduit par " .. ent.driver_name .. ".")
                return itemstack
            end
        end

        -- créer véhicule depuis builder
        if not builder.origin or #builder.nodes == 0 then
            minetest.chat_send_player(name, "[moving_nodes] Aucune structure définie. Utilise glue ou /moving_nodes_fill.")
            return itemstack
        end

        local obj = minetest.add_entity(builder.origin, "moving_nodes:vehicle")
        if not obj then
            minetest.chat_send_player(name, "[moving_nodes] Impossible de créer le véhicule.")
            return itemstack
        end

        local ent = obj:get_luaentity()
        if not ent then
            obj:remove()
            return itemstack
        end

        copy_structure_from_builder(ent)
        current_vehicle = obj
        builder_clear()

        ent.driver_name = name
        ent.old_physics = user:get_physics_override()
        user:set_physics_override({speed = 0, jump = 0})

        ent.driver_offset = vector.subtract(player_pos, ent.structure.origin)

        minetest.chat_send_player(name, "[moving_nodes] Véhicule créé. Mouvement fluide activé.")
        return itemstack
    end,
})

------------------------------------------------------------
-- Commandes Blueprints (save/load/list/delete)
------------------------------------------------------------

minetest.register_chatcommand("moving_nodes_save", {
    params = "<nom>",
    description = "Sauvegarde la structure actuelle comme un plan nommé",
    func = function(name, param)
        local bp_name = param:match("^(%S+)$")
        if not bp_name then
            return false, "[moving_nodes] Utilisation : /moving_nodes_save <nom>"
        end

        if not builder.origin or #builder.nodes == 0 then
            return false, "[moving_nodes] Aucune structure à sauvegarder (glue ou /moving_nodes_fill)."
        end

        local origin = builder.origin
        local offsets = {}
        local nodes = {}

        for i, abs_pos in ipairs(builder.nodes) do
            local off = vector.subtract(abs_pos, origin)
            offsets[i] = { x = off.x, y = off.y, z = off.z }

            local nd = minetest.get_node(abs_pos)
            nodes[i] = { name = nd.name, param2 = nd.param2 or 0 }
        end

        blueprints[bp_name] = { offsets = offsets, nodes = nodes }
        save_blueprints()

        return true, ('[moving_nodes] Plan "%s" sauvegardé (%d nodes).'):format(bp_name, #offsets)
    end,
})

minetest.register_chatcommand("moving_nodes_list", {
    description = "Liste les plans sauvegardés",
    func = function(name, param)
        local names = {}
        for bp_name, bp in pairs(blueprints) do
            table.insert(names, bp_name .. " (" .. tostring(#(bp.offsets or {})) .. " nodes)")
        end
        if #names == 0 then
            return true, "[moving_nodes] Aucun plan sauvegardé."
        end
        table.sort(names)
        return true, "[moving_nodes] Plans : " .. table.concat(names, ", ")
    end,
})

minetest.register_chatcommand("moving_nodes_delete", {
    params = "<nom>",
    description = "Supprime un plan sauvegardé",
    func = function(name, param)
        local bp_name = param:match("^(%S+)$")
        if not bp_name then
            return false, "[moving_nodes] Utilisation : /moving_nodes_delete <nom>"
        end
        if not blueprints[bp_name] then
            return false, ('[moving_nodes] Plan "%s" introuvable.'):format(bp_name)
        end
        blueprints[bp_name] = nil
        save_blueprints()
        return true, ('[moving_nodes] Plan "%s" supprimé.'):format(bp_name)
    end,
})

minetest.register_chatcommand("moving_nodes_load", {
    params = "<nom>",
    description = "Charge un plan et recrée la structure à la position du joueur (puis harnais)",
    func = function(name, param)
        local bp_name = param:match("^(%S+)$")
        if not bp_name then
            return false, "[moving_nodes] Utilisation : /moving_nodes_load <nom>"
        end

        local bp = blueprints[bp_name]
        if not bp or not bp.offsets or not bp.nodes then
            return false, ('[moving_nodes] Plan "%s" introuvable ou invalide.'):format(bp_name)
        end

        if current_vehicle then
            return false, "[moving_nodes] Un véhicule existe déjà. /moving_nodes_reset avant de charger."
        end

        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "[moving_nodes] Joueur introuvable."
        end

        local base_pos = vector.round(player:get_pos())
        builder_clear()
        builder.origin = vector.new(base_pos)
        builder.nodes = {}

        for i, off in ipairs(bp.offsets) do
            local nd = bp.nodes[i]
            if nd and nd.name and nd.name ~= "air" then
                local pos = vector.add(base_pos, off)
                minetest.set_node(pos, { name = nd.name, param2 = nd.param2 or 0 })
                table.insert(builder.nodes, vector.new(pos))
            end
        end

        return true, ('[moving_nodes] Plan "%s" chargé ici. Utilise le harnais pour créer le véhicule.'):format(bp_name)
    end,
})

------------------------------------------------------------
-- RESET
------------------------------------------------------------

minetest.register_chatcommand("moving_nodes_reset", {
    description = "Réinitialise le véhicule et la structure en cours",
    func = function(name, param)
        if current_vehicle then
            local ent = current_vehicle:get_luaentity()
            if ent and ent.driver_name then
                local driver = minetest.get_player_by_name(ent.driver_name)
                if driver and ent.old_physics then
                    driver:set_physics_override(ent.old_physics)
                end
            end
            current_vehicle:remove()
            current_vehicle = nil
        end

        builder_clear()
        return true, "[moving_nodes] Véhicule et structure réinitialisés."
    end,
})

