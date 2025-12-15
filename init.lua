------------------------------------------------------------
-- moving_nodes : véhicule portant une structure de nodes --
------------------------------------------------------------

-- Construction temporaire de la structure (avant création du véhicule)
local builder = {
    nodes = {},    -- positions absolues des nodes choisis
    origin = nil,  -- premier node ajouté (origine de la structure)
}

-- Véhicule courant (un seul pour l'instant)
local current_vehicle = nil

------------------------------------------------------------
-- Blueprints (plans de véhicules) sauvegardés
------------------------------------------------------------

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


------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function builder_clear()
    builder.nodes = {}
    builder.origin = nil
end

-- Retourne true si deux positions sont égales (entier)
local function pos_equal(a, b)
    return a.x == b.x and a.y == b.y and a.z == b.z
end

-- calcule la position monde d’un offset par rapport à une origine flottante
local function world_pos_from_origin(origin, offset)
    return {
        x = math.floor(origin.x + offset.x + 0.5),
        y = math.floor(origin.y + offset.y + 0.5),
        z = math.floor(origin.z + offset.z + 0.5),
    }
end

------------------------------------------------------------
-- OUTIL : colle (construction de la structure)
------------------------------------------------------------

minetest.register_tool("moving_nodes:glue", {
    description = "Outil de colle (définir la structure mobile)",
    inventory_image = "moving_nodes_glue.png",
    wield_image = "moving_nodes_glue.png",

    on_use = function(itemstack, user, pointed_thing)
        local name = user:get_player_name()

        if current_vehicle then
            minetest.chat_send_player(name,
                "[moving_nodes] Un véhicule existe déjà. Utilise /moving_nodes_reset avant de modifier la structure.")
            return itemstack
        end

        if pointed_thing.type ~= "node" then
            return itemstack
        end

        local pos = pointed_thing.under

        -- Si le node est déjà dans la structure : on le retire
        for i, p in ipairs(builder.nodes) do
            if pos_equal(p, pos) then
                table.remove(builder.nodes, i)
                if #builder.nodes == 0 then
                    builder.origin = nil
                    minetest.chat_send_player(name, "[moving_nodes] Structure vide.")
                else
                    minetest.chat_send_player(name, "[moving_nodes] Node retiré de la structure.")
                end
                return itemstack
            end
        end

        -- Sinon on l'ajoute (sauf air)
        local node = minetest.get_node(pos)
        if node.name == "air" then
            minetest.chat_send_player(name, "[moving_nodes] Impossible de coller l'air.")
            return itemstack
        end

        table.insert(builder.nodes, vector.new(pos))

        if not builder.origin then
            builder.origin = vector.new(pos)
        end

        minetest.chat_send_player(name,
            "[moving_nodes] Node ajouté. Total: " .. #builder.nodes)
        return itemstack
    end,
})

------------------------------------------------------------
-- Structure portée par le véhicule
--
-- structure = {
--   origin  = {x,y,z} flottant (position logique de la structure)
--   offsets = { {x,y,z}, ... }  -- offsets entiers par rapport à origin
--   nodes   = { {name=..., param2=...}, ... } -- type de chaque node
-- }
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
        offsets[i] = {
            x = off.x,
            y = off.y,
            z = off.z,
        }

        local node = minetest.get_node(abs_pos)
        nodes[i] = {
            name = node.name,
            param2 = node.param2 or 0,
        }
    end

    self.structure = {
        origin = origin,
        offsets = offsets,
        nodes = nodes,
    }
end

-- Vérifie si la structure peut se déplacer de delta sans collision
local function can_move_structure(structure, delta)
    if not structure or not structure.origin or not structure.offsets then
        return false
    end

    local origin = structure.origin
    local offsets = structure.offsets

    -- index des positions actuelles de la structure
    local current_index = {}
    for _, off in ipairs(offsets) do
        local p = world_pos_from_origin(origin, off)
        current_index[minetest.pos_to_string(p)] = true
    end

    local new_origin = vector.add(origin, delta)

    for _, off in ipairs(offsets) do
        local dest = world_pos_from_origin(new_origin, off)
        local dest_key = minetest.pos_to_string(dest)

        -- Si la destination est déjà occupée par la structure elle-même,
        -- on ignore (pas de collision avec soi-même)
        if not current_index[dest_key] then
            local node = minetest.get_node(dest)
            local def = minetest.registered_nodes[node.name]

            -- on bloque si c'est walkable (mur, sol, etc.), sauf air/ignore
            if node.name ~= "air" and node.name ~= "ignore" then
                if not def or def.walkable then
                    return false
                end
            end
        end
    end

    return true
end

-- Déplace la structure de delta
local function move_structure(structure, delta)
    if not structure or not structure.origin or not structure.offsets or not structure.nodes then
        return
    end

    local old_origin = vector.new(structure.origin)
    local new_origin = vector.add(structure.origin, delta)

    local old_positions = {}
    local new_positions = {}

    for i, off in ipairs(structure.offsets) do
        local old_pos = world_pos_from_origin(old_origin, off)
        local new_pos = world_pos_from_origin(new_origin, off)
        old_positions[i] = old_pos
        new_positions[i] = new_pos
    end

    -- supprimer les anciens nodes
    for _, p in ipairs(old_positions) do
        minetest.remove_node(p)
    end

    -- placer les nouveaux nodes avec les types enregistrés
    for i, p in ipairs(new_positions) do
        local nd = structure.nodes[i]
        if nd and nd.name and nd.name ~= "air" then
            minetest.set_node(p, { name = nd.name, param2 = nd.param2 or 0 })
        end
    end

    structure.origin = new_origin
end

------------------------------------------------------------
-- ENTITÉ VÉHICULE
------------------------------------------------------------

minetest.register_entity("moving_nodes:vehicle", {
    initial_properties = {
        physical = true,
        collide_with_objects = true,
        collisionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5}, -- hitbox simple
        selectionbox = {-0.5, -0.5, -0.5, 0.5, 0.5, 0.5},
        visual = "cube",
        visual_size = {x = 1, y = 1},
        textures = {
            "blank.png",
            "blank.png",
            "blank.png",
            "blank.png",
            "blank.png",
            "blank.png",
        },
        static_save = true,
    },

    driver_name = nil,
    structure = nil,
    move_speed = 5,      -- blocs/seconde
    vertical_speed = 4,  -- vitesse montée/descente

    on_activate = function(self, staticdata, dtime_s)
        if staticdata and staticdata ~= "" then
            local data = minetest.deserialize(staticdata)
            if data and data.structure then
                self.structure = data.structure
            end
        end
    end,

    get_staticdata = function(self)
        return minetest.serialize({
            structure = self.structure,
        })
    end,

    on_step = function(self, dtime)
        local driver = self.driver_name and minetest.get_player_by_name(self.driver_name)
        if not driver then
            return
        end
        if not self.structure or not self.structure.origin or not self.structure.offsets
            or #self.structure.offsets == 0 then
            return
        end

        local ctrl = driver:get_player_control()
        if not ctrl then return end

        -- Direction basée sur le regard du joueur
        local yaw = driver:get_look_horizontal() or 0
        self.object:set_yaw(yaw)

        local forward = {
            x = -math.sin(yaw),
            y = 0,
            z =  math.cos(yaw),
        }
        local right = {
            x = forward.z,
            y = 0,
            z = -forward.x,
        }

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

        if ctrl.jump then
            dir.y = dir.y + self.vertical_speed
        end
        if ctrl.sneak then
            dir.y = dir.y - self.vertical_speed
        end

        -- normalisation horizontale pour éviter d'aller plus vite en diagonale
        local horiz_len = math.sqrt(dir.x * dir.x + dir.z * dir.z)
        if horiz_len > 0 then
            dir.x = dir.x / horiz_len
            dir.z = dir.z / horiz_len
        end

        -- Si aucune entrée, on ne bouge pas
        if dir.x == 0 and dir.y == 0 and dir.z == 0 then
            return
        end

        local delta = {
            x = dir.x * self.move_speed * dtime,
            y = dir.y * dtime, -- vertical_speed déjà dans dir.y
            z = dir.z * self.move_speed * dtime,
        }

        -- arrondi léger pour limiter la dérive flottante
        local function round_comp(v)
            return math.floor(v * 100 + 0.5) / 100
        end
        delta.x = round_comp(delta.x)
        delta.y = round_comp(delta.y)
        delta.z = round_comp(delta.z)

        -- Test de collision pour la structure
        if not can_move_structure(self.structure, delta) then
            return
        end

        -- Déplacement de la structure (nodes)
        move_structure(self.structure, delta)

        -- Synchroniser la position de l'entité avec l'origine
        local veh_pos = world_pos_from_origin(self.structure.origin, {x = 0, y = 0, z = 0})
        self.object:set_pos(veh_pos)
    end,

    on_punch = function(self, puncher, time_from_last_punch, tool_capabilities, dir)
        -- tu peux ici détruire le véhicule si tu veux
        -- self.object:remove()
        -- current_vehicle = nil
    end,

    on_rightclick = function(self, clicker)
        -- non utilisé, on passe par l’outil d’attache
    end,
})

------------------------------------------------------------
-- OUTIL : harnais (créer/monter/descendre du véhicule)
------------------------------------------------------------

minetest.register_tool("moving_nodes:harness", {
    description = "Outil d'attache au véhicule",
    inventory_image = "moving_nodes_harness.png",
    wield_image = "moving_nodes_harness.png",

    on_use = function(itemstack, user, pointed_thing)
        local name = user:get_player_name()
        local player_pos = user:get_pos()

        ------------------------------------------------
        -- Cas 1 : un véhicule existe déjà
        ------------------------------------------------
        if current_vehicle then
            local ent = current_vehicle:get_luaentity()
            if not ent then
                current_vehicle = nil
                minetest.chat_send_player(name, "[moving_nodes] Véhicule invalide, réinitialisé.")
                return itemstack
            end

            -- joueur déjà conducteur -> descendre
            if ent.driver_name == name then
                ent.driver_name = nil
                user:set_detach()
                minetest.chat_send_player(name, "[moving_nodes] Tu quittes le véhicule.")
                return itemstack
            end

            -- pas encore de conducteur -> monter depuis la position actuelle
            if not ent.driver_name then
                ent.driver_name = name

                local veh_pos = current_vehicle:get_pos()
                if not veh_pos then veh_pos = {x = 0, y = 0, z = 0} end

                -- offset = où est le joueur par rapport au centre du véhicule
                local offset = vector.subtract(player_pos, veh_pos)
                -- option : remonter un peu pour être sûr au-dessus
                offset.y = offset.y + 0.5

                user:set_attach(current_vehicle, "", offset, {x = 0, y = 0, z = 0})
                minetest.chat_send_player(name, "[moving_nodes] Tu montes dans le véhicule.")
                return itemstack
            else
                minetest.chat_send_player(name,
                    "[moving_nodes] Le véhicule est déjà conduit par " .. ent.driver_name .. ".")
                return itemstack
            end
        end

        ------------------------------------------------
        -- Cas 2 : aucun véhicule -> on en crée un
        ------------------------------------------------
        if #builder.nodes == 0 or not builder.origin then
            minetest.chat_send_player(name,
                "[moving_nodes] Aucune structure définie. Utilise d'abord l'outil de colle.")
            return itemstack
        end

        -- spawn du véhicule à l'origine
        local obj = minetest.add_entity(builder.origin, "moving_nodes:vehicle")
        if not obj then
            minetest.chat_send_player(name, "[moving_nodes] Impossible de créer le véhicule.")
            return itemstack
        end

        local ent = obj:get_luaentity()
        if not ent then
            obj:remove()
            minetest.chat_send_player(name, "[moving_nodes] Erreur lors de la création de l'entité véhicule.")
            return itemstack
        end

        copy_structure_from_builder(ent)
        current_vehicle = obj
        builder_clear()

        -- attacher immédiatement le joueur comme conducteur à l'endroit où il se trouve
        ent.driver_name = name

        local veh_pos = current_vehicle:get_pos()
        if not veh_pos then veh_pos = {x = 0, y = 0, z = 0} end

        local offset = vector.subtract(player_pos, veh_pos)
        offset.y = offset.y + 0.5

        user:set_attach(obj, "", offset, {x = 0, y = 0, z = 0})
        minetest.chat_send_player(name,
            "[moving_nodes] Véhicule créé. Tes inputs contrôlent maintenant la structure.")

        return itemstack
    end,
})

------------------------------------------------------------
-- /moving_nodes_save <nom>
-- Sauvegarde la structure collée actuellement dans un plan nommé
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
            return false, "[moving_nodes] Aucune structure à sauvegarder (utilise l'outil de colle d'abord)."
        end

        -- Construire le blueprint (offsets + types de nodes)
        local origin = builder.origin
        local offsets = {}
        local nodes = {}

        for i, abs_pos in ipairs(builder.nodes) do
            local off = vector.subtract(abs_pos, origin)
            offsets[i] = {
                x = off.x,
                y = off.y,
                z = off.z,
            }

            local node = minetest.get_node(abs_pos)
            nodes[i] = {
                name = node.name,
                param2 = node.param2 or 0,
            }
        end

        blueprints[bp_name] = {
            offsets = offsets,
            nodes = nodes,
        }
        save_blueprints()

        return true, "[moving_nodes] Plan \"" .. bp_name .. "\" sauvegardé (" .. #offsets .. " nodes)."
    end,
})

------------------------------------------------------------
-- /moving_nodes_list
-- Liste les plans disponibles
------------------------------------------------------------

minetest.register_chatcommand("moving_nodes_list", {
    description = "Liste les plans de véhicules sauvegardés",
    func = function(name, param)
        local names = {}
        for bp_name, bp in pairs(blueprints) do
            table.insert(names, bp_name .. " (" .. #bp.offsets .. " nodes)")
        end

        if #names == 0 then
            return true, "[moving_nodes] Aucun plan sauvegardé."
        end

        table.sort(names)
        return true, "[moving_nodes] Plans disponibles : " .. table.concat(names, ", ")
    end,
})

------------------------------------------------------------
-- /moving_nodes_delete <nom>
-- Supprime un plan
------------------------------------------------------------

minetest.register_chatcommand("moving_nodes_delete", {
    params = "<nom>",
    description = "Supprime un plan de véhicule sauvegardé",
    func = function(name, param)
        local bp_name = param:match("^(%S+)$")
        if not bp_name then
            return false, "[moving_nodes] Utilisation : /moving_nodes_delete <nom>"
        end

        if not blueprints[bp_name] then
            return false, "[moving_nodes] Plan \"" .. bp_name .. "\" introuvable."
        end

        blueprints[bp_name] = nil
        save_blueprints()

        return true, "[moving_nodes] Plan \"" .. bp_name .. "\" supprimé."
    end,
})

------------------------------------------------------------
-- /moving_nodes_load <nom>
-- Recrée la structure d'un plan sous le joueur et la sélectionne
------------------------------------------------------------

minetest.register_chatcommand("moving_nodes_load", {
    params = "<nom>",
    description = "Charge un plan de véhicule et recrée la structure sous le joueur",
    func = function(name, param)
        local bp_name = param:match("^(%S+)$")
        if not bp_name then
            return false, "[moving_nodes] Utilisation : /moving_nodes_load <nom>"
        end

        local bp = blueprints[bp_name]
        if not bp then
            return false, "[moving_nodes] Plan \"" .. bp_name .. "\" introuvable."
        end

        if current_vehicle then
            return false, "[moving_nodes] Un véhicule existe déjà. Utilise /moving_nodes_reset avant de charger un plan."
        end

        local player = minetest.get_player_by_name(name)
        if not player then
            return false, "[moving_nodes] Joueur introuvable."
        end

        local base_pos = vector.round(player:get_pos())

        -- On efface l'ancien builder
        builder_clear()

        builder.origin = vector.new(base_pos)
        builder.nodes = {}

        -- Recréer les nodes dans le monde
        for i, off in ipairs(bp.offsets) do
            local nd = bp.nodes[i]
            if nd and nd.name and nd.name ~= "air" then
                local pos = vector.add(base_pos, off)
                minetest.set_node(pos, { name = nd.name, param2 = nd.param2 or 0 })
                table.insert(builder.nodes, pos)
            end
        end

        return true, "[moving_nodes] Plan \"" .. bp_name .. "\" chargé à ta position. Utilise le harnais pour créer le véhicule."
    end,
})


------------------------------------------------------------
-- COMMANDE : reset complet
------------------------------------------------------------

minetest.register_chatcommand("moving_nodes_reset", {
    description = "Réinitialise le véhicule et la structure du mod moving_nodes",
    func = function(name, param)
        if current_vehicle then
            local ent = current_vehicle:get_luaentity()
            if ent and ent.driver_name then
                local player = minetest.get_player_by_name(ent.driver_name)
                if player then
                    player:set_detach()
                end
            end
            current_vehicle:remove()
            current_vehicle = nil
        end

        builder_clear()
        return true, "[moving_nodes] Véhicule et structure réinitialisés."
    end,
})

------------------------------------------------------------
-- Sélection de volume (pos1/pos2) + collage automatique
------------------------------------------------------------

local selections = {} -- selections[playername] = {pos1=..., pos2=...}

local function get_pointed_node_pos(player)
    local pt = player and player:get_pointed_thing()
    if pt and pt.type == "node" then
        return pt.under
    end
    return nil
end

local function set_sel(name, which, pos)
    selections[name] = selections[name] or {}
    selections[name][which] = vector.round(pos)
end

local function get_sel(name)
    local s = selections[name]
    if not s or not s.pos1 or not s.pos2 then return nil end
    return s.pos1, s.pos2
end

local function minmax(a, b)
    return math.min(a, b), math.max(a, b)
end

local function volume_size(p1, p2)
    local x1, x2 = minmax(p1.x, p2.x)
    local y1, y2 = minmax(p1.y, p2.y)
    local z1, z2 = minmax(p1.z, p2.z)
    return (x2 - x1 + 1) * (y2 - y1 + 1) * (z2 - z1 + 1)
end

-- /moving_nodes_pos1 [point]
-- Sans argument: prend la position du joueur (arrondie)
-- Avec "point": prend le node visé
minetest.register_chatcommand("moving_nodes_pos1", {
    params = "[point]",
    description = "Définit le coin 1 du volume (utilise 'point' pour prendre le node visé)",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "[moving_nodes] Joueur introuvable." end

        local pos
        if param == "point" then
            pos = get_pointed_node_pos(player)
            if not pos then
                return false, "[moving_nodes] Aucun node visé."
            end
        else
            pos = player:get_pos()
        end

        set_sel(name, "pos1", pos)
        local p1 = selections[name].pos1
        return true, ("[moving_nodes] pos1 = %d,%d,%d"):format(p1.x, p1.y, p1.z)
    end,
})

-- /moving_nodes_pos2 [point]
minetest.register_chatcommand("moving_nodes_pos2", {
    params = "[point]",
    description = "Définit le coin 2 du volume (utilise 'point' pour prendre le node visé)",
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "[moving_nodes] Joueur introuvable." end

        local pos
        if param == "point" then
            pos = get_pointed_node_pos(player)
            if not pos then
                return false, "[moving_nodes] Aucun node visé."
            end
        else
            pos = player:get_pos()
        end

        set_sel(name, "pos2", pos)
        local p2 = selections[name].pos2
        return true, ("[moving_nodes] pos2 = %d,%d,%d"):format(p2.x, p2.y, p2.z)
    end,
})

-- /moving_nodes_fill
-- Colle tous les nodes (non-air) dans le volume pos1-pos2
minetest.register_chatcommand("moving_nodes_fill", {
    description = "Colle tous les nodes (non-air) inclus dans le volume pos1-pos2",
    func = function(name, param)
        if current_vehicle then
            return false, "[moving_nodes] Un véhicule existe déjà. Utilise /moving_nodes_reset avant."
        end

        local p1, p2 = get_sel(name)
        if not p1 or not p2 then
            return false, "[moving_nodes] Définis d'abord pos1 et pos2 avec /moving_nodes_pos1 et /moving_nodes_pos2."
        end

        local max_nodes = 20000 -- garde-fou anti-lag
        local total = volume_size(p1, p2)
        if total > max_nodes then
            return false, ("[moving_nodes] Volume trop grand (%d nodes). Limite: %d."):format(total, max_nodes)
        end

        -- On remplace la sélection actuelle
        builder_clear()

        local x1, x2 = minmax(p1.x, p2.x)
        local y1, y2 = minmax(p1.y, p2.y)
        local z1, z2 = minmax(p1.z, p2.z)

        -- Origine stable = coin "min" du volume
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

-- Optionnel : reset juste la sélection pos1/pos2
minetest.register_chatcommand("moving_nodes_selclear", {
    description = "Efface pos1/pos2 pour toi",
    func = function(name, param)
        selections[name] = nil
        return true, "[moving_nodes] Sélection effacée."
    end,
})


------------------------------------------------------------
-- Aperçu visuel de la sélection (particules coins + contour)
------------------------------------------------------------

local PREVIEW_INTERVAL = 0.25      -- secondes
local PREVIEW_LIFETIME = 0.35      -- doit être >= interval pour éviter clignotement
local PREVIEW_MAX_POINTS = 1200    -- limite anti-lag (arêtes)
local PREVIEW_STEP = 1             -- 1 = chaque node, 2 = un point sur 2, etc.

local function minmax(a, b) return math.min(a, b), math.max(a, b) end

local function get_box(p1, p2)
    local x1, x2 = minmax(p1.x, p2.x)
    local y1, y2 = minmax(p1.y, p2.y)
    local z1, z2 = minmax(p1.z, p2.z)
    return x1, y1, z1, x2, y2, z2
end

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
        playername = playername, -- particule visible uniquement pour ce joueur
    })
end

local function add_edge_points(playername, a, b, step)
    step = step or PREVIEW_STEP
    local dx = b.x - a.x
    local dy = b.y - a.y
    local dz = b.z - a.z

    local n = math.max(math.abs(dx), math.abs(dy), math.abs(dz))
    if n == 0 then
        add_particle(playername, a, 4)
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
        if count >= PREVIEW_MAX_POINTS then
            break
        end
    end
    return count
end

local function show_selection_preview(playername, p1, p2)
    local x1, y1, z1, x2, y2, z2 = get_box(p1, p2)

    -- 8 coins
    local c000 = {x=x1, y=y1, z=z1}
    local c100 = {x=x2, y=y1, z=z1}
    local c010 = {x=x1, y=y2, z=z1}
    local c110 = {x=x2, y=y2, z=z1}
    local c001 = {x=x1, y=y1, z=z2}
    local c101 = {x=x2, y=y1, z=z2}
    local c011 = {x=x1, y=y2, z=z2}
    local c111 = {x=x2, y=y2, z=z2}

    -- coins plus visibles
    add_particle(playername, c000, 8)
    add_particle(playername, c100, 8)
    add_particle(playername, c010, 8)
    add_particle(playername, c110, 8)
    add_particle(playername, c001, 8)
    add_particle(playername, c101, 8)
    add_particle(playername, c011, 8)
    add_particle(playername, c111, 8)

    -- 12 arêtes (contour)
    local used = 0
    used = used + add_edge_points(playername, c000, c100)
    used = used + add_edge_points(playername, c000, c010)
    used = used + add_edge_points(playername, c000, c001)

    used = used + add_edge_points(playername, c111, c101)
    used = used + add_edge_points(playername, c111, c110)
    used = used + add_edge_points(playername, c111, c011)

    used = used + add_edge_points(playername, c001, c101)
    used = used + add_edge_points(playername, c001, c011)

    used = used + add_edge_points(playername, c010, c110)
    used = used + add_edge_points(playername, c010, c011)

    used = used + add_edge_points(playername, c100, c110)
    used = used + add_edge_points(playername, c100, c101)
end

-- Boucle globale : rafraîchit l’aperçu pour chaque joueur ayant une sélection
local preview_timer = 0
minetest.register_globalstep(function(dtime)
    preview_timer = preview_timer + dtime
    if preview_timer < PREVIEW_INTERVAL then return end
    preview_timer = 0

    for playername, sel in pairs(selections) do
        if sel and sel.pos1 and sel.pos2 then
            local player = minetest.get_player_by_name(playername)
            if player then
                -- Option : ne pas afficher si trop loin (anti spam visuel)
                -- local pp = vector.round(player:get_pos())
                -- if vector.distance(pp, sel.pos1) < 200 or vector.distance(pp, sel.pos2) < 200 then
                show_selection_preview(playername, sel.pos1, sel.pos2)
                -- end
            end
        end
    end
end)

