local movable_structure = {
    nodes = {},            -- liste de positions {x,y,z}
    node_index = {},       -- pos_string -> index dans nodes
    origin = nil,          -- position de référence (premier node ajouté)
    attached_player = nil, -- name du joueur
    player_offset = nil,   -- vector: player_pos - origin
    old_physics = {},      -- sauvegarde des physics_override du joueur
}

local function rebuild_index()
    movable_structure.node_index = {}
    for i, pos in ipairs(movable_structure.nodes) do
        movable_structure.node_index[minetest.pos_to_string(pos)] = i
    end
end

local function restore_player_physics(name)
    local old = movable_structure.old_physics[name]
    if not old then return end
    local player = minetest.get_player_by_name(name)
    if player then
        player:set_physics_override(old)
    end
    movable_structure.old_physics[name] = nil
end

local function clear_structure()
    if movable_structure.attached_player then
        restore_player_physics(movable_structure.attached_player)
    end

    movable_structure.nodes = {}
    movable_structure.node_index = {}
    movable_structure.origin = nil
    movable_structure.attached_player = nil
    movable_structure.player_offset = nil
end

-- =========================================================
-- Outil : colle de nodes (Glue Tool)
-- =========================================================
minetest.register_tool("moving_nodes:glue", {
    description = "Outil de colle (coller/décoller les nodes dans un groupe)",
    inventory_image = "moving_nodes_glue.png",
    wield_image = "moving_nodes_glue.png",

    on_use = function(itemstack, user, pointed_thing)
        if pointed_thing.type ~= "node" then
            return itemstack
        end

        local pos = pointed_thing.under
        local pos_str = minetest.pos_to_string(pos)
        local name = user:get_player_name()

        -- Si le node est déjà dans le groupe : on le retire
        if movable_structure.node_index[pos_str] then
            local idx = movable_structure.node_index[pos_str]
            table.remove(movable_structure.nodes, idx)
            rebuild_index()

            -- Si plus de nodes -> on reset tout
            if #movable_structure.nodes == 0 then
                clear_structure()
                minetest.chat_send_player(name, "[moving_nodes] Groupe vidé.")
            else
                minetest.chat_send_player(name, "[moving_nodes] Node retiré du groupe.")
            end

            return itemstack
        end

        -- Si ce n'est pas de l'air, on l’ajoute
        local node = minetest.get_node(pos)
        if node.name == "air" then
            minetest.chat_send_player(name, "[moving_nodes] Impossible de coller l'air.")
            return itemstack
        end

        table.insert(movable_structure.nodes, vector.new(pos))
        movable_structure.node_index[pos_str] = #movable_structure.nodes

        if not movable_structure.origin then
            movable_structure.origin = vector.new(pos)
        end

        minetest.chat_send_player(name, "[moving_nodes] Node ajouté au groupe. Total: " .. #movable_structure.nodes)
        return itemstack
    end,
})

-- =========================================================
-- Outil : attacher le joueur au groupe (Harness Tool)
-- =========================================================
minetest.register_tool("moving_nodes:harness", {
    description = "Outil d'attache au groupe de nodes (mode véhicule)",
    inventory_image = "moving_nodes_harness.png",
    wield_image = "moving_nodes_harness.png",

    on_use = function(itemstack, user, pointed_thing)
        local name = user:get_player_name()

        -- Si le joueur est déjà attaché : on le détache
        if movable_structure.attached_player == name then
            restore_player_physics(name)
            movable_structure.attached_player = nil
            movable_structure.player_offset = nil
            minetest.chat_send_player(name, "[moving_nodes] Détaché du groupe (véhicule).")
            return itemstack
        end

        -- Sinon, on l'attache
        if #movable_structure.nodes == 0 or not movable_structure.origin then
            minetest.chat_send_player(name, "[moving_nodes] Aucun groupe de nodes défini. Utilise d'abord l'outil de colle.")
            return itemstack
        end

        local player_pos = user:get_pos()
        if not player_pos then
            return itemstack
        end

        -- Sauvegarde des physics du joueur et blocage du mouvement normal
        movable_structure.old_physics[name] = user:get_physics_override()
        user:set_physics_override({
            speed = 0,
            jump = 0,
            sneak = movable_structure.old_physics[name].sneak, -- on garde l'info de sneak si tu veux
        })

        movable_structure.attached_player = name
        movable_structure.player_offset = vector.subtract(player_pos, movable_structure.origin)

        minetest.chat_send_player(name, "[moving_nodes] Tu es maintenant attaché au groupe (mode véhicule). Tes touches déplacent la structure.")
        return itemstack
    end,
})

-- =========================================================
-- Déplacement du groupe en mode véhicule
-- =========================================================

local move_speed = 5      -- blocs par seconde
local vertical_speed = 4  -- vitesse montée/descente avec saut/accroupi

minetest.register_globalstep(function(dtime)
    local player_name = movable_structure.attached_player
    if not player_name then
        return
    end

    if #movable_structure.nodes == 0 or not movable_structure.origin then
        restore_player_physics(player_name)
        movable_structure.attached_player = nil
        movable_structure.player_offset = nil
        return
    end

    local player = minetest.get_player_by_name(player_name)
    if not player then
        -- joueur déconnecté
        restore_player_physics(player_name)
        movable_structure.attached_player = nil
        movable_structure.player_offset = nil
        return
    end

    local ctrl = player:get_player_control()
    if not ctrl then return end

    -- Direction à partir du regard du joueur
    local yaw = player:get_look_horizontal() or 0
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

    -- Vertical : jump / sneak pour monter / descendre
    if ctrl.jump then
        dir.y = dir.y + vertical_speed
    end
    if ctrl.sneak then
        dir.y = dir.y - vertical_speed
    end

    -- Normalisation horizontale (pour ne pas aller plus vite en diagonale)
    local horiz_len = math.sqrt(dir.x * dir.x + dir.z * dir.z)
    if horiz_len > 0 then
        dir.x = dir.x / horiz_len
        dir.z = dir.z / horiz_len
    end

    -- Si aucune entrée, rien à faire
    if dir.x == 0 and dir.y == 0 and dir.z == 0 then
        return
    end

    -- Delta de mouvement
    local delta = {
        x = dir.x * move_speed * dtime,
        y = dir.y * dtime, -- vertical_speed déjà multiplié dans dir.y
        z = dir.z * move_speed * dtime,
    }

    -- Snap léger pour éviter l’accumulation de flottants
    local function round_pos(p)
        return {
            x = math.floor(p.x * 100 + 0.5) / 100,
            y = math.floor(p.y * 100 + 0.5) / 100,
            z = math.floor(p.z * 100 + 0.5) / 100,
        }
    end

    delta = round_pos(delta)

    -- Snapshot des nodes avant déplacement
    local nodes_snapshot = {}
    for i, pos in ipairs(movable_structure.nodes) do
        nodes_snapshot[i] = {
            old_pos = vector.new(pos),
            node = minetest.get_node(pos),
        }
    end

    -- On supprime les anciens nodes
    for _, data in ipairs(nodes_snapshot) do
        minetest.remove_node(data.old_pos)
    end

    -- On place les nouveaux nodes
    local new_nodes = {}
    local new_index = {}
    for i, data in ipairs(nodes_snapshot) do
        local new_pos = vector.add(data.old_pos, delta)
        minetest.set_node(new_pos, data.node)

        new_nodes[i] = new_pos
        new_index[minetest.pos_to_string(new_pos)] = i
    end

    movable_structure.nodes = new_nodes
    movable_structure.node_index = new_index

    if movable_structure.origin then
        movable_structure.origin = vector.add(movable_structure.origin, delta)
    end

    -- Déplacement du joueur pour qu’il garde la même offset par rapport à l’origine
    if movable_structure.player_offset then
        local target_pos = vector.add(movable_structure.origin, movable_structure.player_offset)
        player:set_pos(target_pos)
    end
end)

-- =========================================================
-- Commande pratique pour vider le groupe
-- =========================================================
minetest.register_chatcommand("moving_nodes_clear", {
    description = "Efface le groupe de nodes du mod moving_nodes",
    func = function(name, param)
        clear_structure()
        return true, "[moving_nodes] Groupe réinitialisé."
    end,
})

