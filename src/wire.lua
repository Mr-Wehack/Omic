-- Модуль генерации, отрисовки меша, отладки и анализа топологии проводов
local solver = require("src.core.solver")

local M = {}

M.THICKNESS = 10.0 -- Базовая толщина провода
M.SEGMENTS = 48    -- Количество сегментов кривой Безье

-- Цветовые палитры для темного и светлого режимов
M.THEME_COLORS = {
	dark = {
		wire = vmath.vector4(0.25, 0.65, 0.95, 1.0),     -- Основной провод
		preview = vmath.vector4(0.45, 0.80, 1.0, 0.55)   -- Предпросмотр при тянущемся проводе
	},
	light = {
		wire = vmath.vector4(0.10, 0.40, 0.75, 1.0),     -- Основной провод
		preview = vmath.vector4(0.10, 0.40, 0.75, 0.50)  -- Предпросмотр
	}
}

-- Преобразование идентификатора объекта в надежный строковый ключ
local function get_id_key(id)
	return tostring(id)
end

-- Генерация уникального строкового ключа для конкретного пина детали
local function get_pin_key(id_or_key, pin_idx)
	return tostring(id_or_key) .. ":" .. tostring(pin_idx)
end

-- Метатаблица для автоматического перевода userdata хешей в строковые ключи
local key_norm_mt = {
	__index = function(t, k)
		if type(k) ~= "string" then
			return rawget(t, tostring(k))
		end
		return nil
	end
}

-- Реестр пинов по ключу объекта
M.pins = setmetatable({}, key_norm_mt)

-- Реестр параметров радиодеталей по ключу объекта
M.components = setmetatable({}, key_norm_mt)

-- Список активных соединений
M.connections = {}

-- Активные предпросмотры проводов
M.previews = setmetatable({}, key_norm_mt)

-- Рассчитанные данные цепи для отладки, интерфейса и шейдеров
M.circuit_results = {
	is_solved = false,
	potentials = {},
	branches = setmetatable({}, key_norm_mt),
	pin_nodes = {}
}

-- Идентификатор объекта с мешем и буфер вершин для видеокарты
M.mesh_id = nil
M.buf = nil
M.buf_vertex_count = 0
M.master_key = nil

-- Кэшированные векторы для минимизации сборки мусора
local temp_mouse_pos = vmath.vector3(0, 0, 0)
local temp_pin_pos = vmath.vector3(0, 0, 0)
local temp_text_pos = vmath.vector3(0, 0, 0)

-- Перевод мировых координат в экранные координаты окна для отрисовки отладочного текста
function M.world_to_screen(world_x, world_y)
	local proj_w = sys.get_config_int("display.width", 960)
	local proj_h = sys.get_config_int("display.height", 640)
	local win_w, win_h = window.get_size()
	local screen_x = world_x + (win_w - proj_w) * 0.5
	local screen_y = world_y + (win_h - proj_h) * 0.5
	temp_text_pos.x = screen_x
	temp_text_pos.y = screen_y
	temp_text_pos.z = 0
	return temp_text_pos
end

-- Получение номера узла для конкретного пина детали
function M.get_pin_node(id, pin_idx)
	local p_key = get_pin_key(id, pin_idx)
	return M.circuit_results.pin_nodes[p_key]
end

-- Регистрация электрических свойств детали
function M.register_component_data(id, comp_type, value)
	local key = get_id_key(id)
	local comp = rawget(M.components, key)
	if not comp then
		rawset(M.components, key, {
			raw_id = id,
			comp_type = comp_type or hash("resistor"),
			value = value or 20.0
		})
	else
		comp.raw_id = id
		if comp_type then comp.comp_type = comp_type end
		if value then comp.value = value end
	end
end

-- Регистрация физических координат пинов детали каждый кадр и авторегистрация параметров
function M.register_pins(id, p1_pos, p1_dir, p2_pos, p2_dir, scale, comp_type, value)
	local key = get_id_key(id)
	if not M.master_key then
		M.master_key = key
	end

	local p = rawget(M.pins, key)
	if not p then
		rawset(M.pins, key, {
			raw_id = id,
			scale = scale or 1.0,
			[1] = { pos = p1_pos, dir = p1_dir },
			[2] = { pos = p2_pos, dir = p2_dir }
		})
	else
		p.raw_id = id
		p.scale = scale or 1.0
		p[1].pos = p1_pos
		p[1].dir = p1_dir
		p[2].pos = p2_pos
		p[2].dir = p2_dir
	end

	-- Автоматическое чтение параметров детали если они еще не были зарегистрированы
	if not rawget(M.components, key) or comp_type or value then
		if not comp_type then
			local ok_t, t_val = pcall(go.get, "#", "comp_type")
			if ok_t then comp_type = t_val end
		end
		if not value then
			local ok_v, v_val = pcall(go.get, "#", "value")
			if ok_v then value = v_val end
		end
		M.register_component_data(id, comp_type, value)
	end
end

-- Поиск ближайшего пина к курсору мыши
function M.find_closest_pin(mouse_x, mouse_y, hit_radius, ignore_id, ignore_pin)
	temp_mouse_pos.x = mouse_x
	temp_mouse_pos.y = mouse_y
	temp_mouse_pos.z = 0

	local ignore_key = ignore_id and get_id_key(ignore_id) or nil
	local best_key = nil
	local best_pin = nil
	local best_dist = math.huge

	for key, pins_data in pairs(M.pins) do
		for pin_idx = 1, 2 do
			if not (key == ignore_key and pin_idx == ignore_pin) then
				local target_radius = math.max(hit_radius, 35.0 * (pins_data.scale or 1.0))
				temp_pin_pos.x = pins_data[pin_idx].pos.x
				temp_pin_pos.y = pins_data[pin_idx].pos.y
				temp_pin_pos.z = 0

				local dist = vmath.length(temp_pin_pos - temp_mouse_pos)
				if dist <= target_radius and dist < best_dist then
					best_dist = dist
					best_key = key
					best_pin = pin_idx
				end
			end
		end
	end
	return best_key, best_pin
end

-- Добавление нового соединения между пинами и запуск пересчета схемы
function M.connect(from_id, from_pin, to_id, to_pin)
	local from_key = get_id_key(from_id)
	local to_key = get_id_key(to_id)

	if from_key == to_key and from_pin == to_pin then return end

	-- Проверка на дубликат чтобы не создавать второй провод поверх существующего
	for _, conn in ipairs(M.connections) do
		local same_dir = (conn.from_key == from_key and conn.from_pin == from_pin and conn.to_key == to_key and conn.to_pin == to_pin)
		local rev_dir  = (conn.from_key == to_key and conn.from_pin == to_pin and conn.to_key == from_key and conn.to_pin == from_pin)
		if same_dir or rev_dir then
			return
		end
	end

	table.insert(M.connections, {
		from_id = from_key,
		from_key = from_key,
		from_pin = from_pin,
		to_id = to_key,
		to_key = to_key,
		to_pin = to_pin
	})

	-- Сразу пересчитываем электрическую цепь после нового соединения
	M.recalculate_circuit()
end

-- Удаление провода от указанного пина детали при нажатии ПКМ
function M.disconnect_pin(id, pin_idx)
	local key = get_id_key(id)
	local removed = false

	-- Ищем с конца списка последнее соединение на этом пине и удаляем его
	for i = #M.connections, 1, -1 do
		local conn = M.connections[i]
		if (conn.from_key == key and conn.from_pin == pin_idx) or (conn.to_key == key and conn.to_pin == pin_idx) then
			table.remove(M.connections, i)
			removed = true
			break
		end
	end

	if removed then
		print(string.format("[Omic Редактор] Удален провод от детали %s (пин %d)", key, pin_idx))
		M.recalculate_circuit()
	end
	return removed
end

-- Сборка топологии графа и запуск математического решателя
function M.recalculate_circuit()
	M.circuit_results.is_solved = false
	M.circuit_results.potentials = {}
	M.circuit_results.branches = setmetatable({}, key_norm_mt)
	M.circuit_results.pin_nodes = {}

	if #M.connections == 0 then
		return
	end

	-- Строим список смежности для всех соединенных проводами пинов
	local adj = {}
	local active_pins = {}

	local function ensure_pin_in_graph(pin_key)
		if not adj[pin_key] then
			adj[pin_key] = {}
			table.insert(active_pins, pin_key)
		end
	end

	for _, conn in ipairs(M.connections) do
		local k1 = get_pin_key(conn.from_key, conn.from_pin)
		local k2 = get_pin_key(conn.to_key, conn.to_pin)
		ensure_pin_in_graph(k1)
		ensure_pin_in_graph(k2)
		table.insert(adj[k1], k2)
		table.insert(adj[k2], k1)
	end

	-- Обход в глубину для группировки соединенных пинов в единые электрические узлы
	local pin_to_raw_node = {}
	local raw_node_count = 0

	local function dfs(current_key, node_id)
		pin_to_raw_node[current_key] = node_id
		for _, neighbor_key in ipairs(adj[current_key]) do
			if not pin_to_raw_node[neighbor_key] then
				dfs(neighbor_key, node_id)
			end
		end
	end

	for _, pin_key in ipairs(active_pins) do
		if not pin_to_raw_node[pin_key] then
			raw_node_count = raw_node_count + 1
			dfs(pin_key, raw_node_count)
		end
	end

	-- Сохраняем предварительные номера узлов для отображения на пинах и проводах
	for pin_key, r_node in pairs(pin_to_raw_node) do
		M.circuit_results.pin_nodes[pin_key] = r_node
	end

	-- Подсчитываем общее число известных деталей и собираем подключенные с двух сторон детали
	local total_registered = 0
	local connected_components = {}
	for comp_key, comp_data in pairs(M.components) do
		total_registered = total_registered + 1
		local r1 = pin_to_raw_node[get_pin_key(comp_key, 1)]
		local r2 = pin_to_raw_node[get_pin_key(comp_key, 2)]

		-- Деталь должна быть подключена обоими концами к разным узлам
		if r1 and r2 and r1 ~= r2 then
			local is_resistor = (comp_data.comp_type == hash("resistor"))
			table.insert(connected_components, {
				key = comp_key,
				raw_id = comp_data.raw_id,
				comp_type = comp_data.comp_type,
				type = is_resistor and "resistor" or "current_source",
				raw_n1 = r1,
				raw_n2 = r2,
				value = comp_data.value
			})
		end
	end

	-- Отсекаем висячие ветви, через которые не может течь замкнутый ток
	local valid_components = connected_components
	local pruned = true
	while pruned do
		pruned = false
		local node_degree = {}
		for _, comp in ipairs(valid_components) do
			node_degree[comp.raw_n1] = (node_degree[comp.raw_n1] or 0) + 1
			node_degree[comp.raw_n2] = (node_degree[comp.raw_n2] or 0) + 1
		end

		local next_list = {}
		for _, comp in ipairs(valid_components) do
			if (node_degree[comp.raw_n1] or 0) >= 2 and (node_degree[comp.raw_n2] or 0) >= 2 then
				table.insert(next_list, comp)
			else
				pruned = true
			end
		end
		valid_components = next_list
	end

	-- Находим все уникальные узлы, оставшиеся в замкнутом контуре
	local active_raw_nodes = {}
	local active_raw_nodes_list = {}
	for _, comp in ipairs(valid_components) do
		if not active_raw_nodes[comp.raw_n1] then
			active_raw_nodes[comp.raw_n1] = true
			table.insert(active_raw_nodes_list, comp.raw_n1)
		end
		if not active_raw_nodes[comp.raw_n2] then
			active_raw_nodes[comp.raw_n2] = true
			table.insert(active_raw_nodes_list, comp.raw_n2)
		end
	end

	print("==========================================")
	print(string.format("[Omic Топология] Деталей на столе: %d | Проводов: %d | Замкнутых узлов: %d | Деталей в контуре: %d",
		total_registered, #M.connections, #active_raw_nodes_list, #valid_components))

	if #valid_components == 0 or #active_raw_nodes_list < 2 then
		print("[Omic Расчет] Контур еще не замкнут. Соедините оба контакта источника и резистора в кольцо.")
		print("==========================================")
		return
	end

	-- Выбираем базовый узел Земля (потенциал 0 Вольт) на первом контакте источника тока
	local ground_raw_node = nil
	for _, comp in ipairs(valid_components) do
		if comp.type == "current_source" then
			ground_raw_node = comp.raw_n1
			break
		end
	end
	if not ground_raw_node then
		ground_raw_node = active_raw_nodes_list[1]
	end

	-- Переиндексация узлов для решателя: Земля получает индекс 0, остальные по порядку
	local raw_to_solver_node = {}
	raw_to_solver_node[ground_raw_node] = 0
	local solver_nodes_count = 0

	for _, r_node in ipairs(active_raw_nodes_list) do
		if r_node ~= ground_raw_node then
			solver_nodes_count = solver_nodes_count + 1
			raw_to_solver_node[r_node] = solver_nodes_count
		end
	end

	-- Обновляем номера узлов для пинов в соответствии с индексами решателя
	for pin_key, r_node in pairs(pin_to_raw_node) do
		if raw_to_solver_node[r_node] ~= nil then
			M.circuit_results.pin_nodes[pin_key] = raw_to_solver_node[r_node]
		end
	end

	-- Формируем итоговый массив компонентов для передачи в математический модуль solver.lua
	local solver_components = {}
	for _, comp in ipairs(valid_components) do
		local n1 = raw_to_solver_node[comp.raw_n1]
		local n2 = raw_to_solver_node[comp.raw_n2]

		if comp.type == "resistor" then
			table.insert(solver_components, {
				key = comp.key,
				raw_id = comp.raw_id,
				type = "resistor",
				n1 = n1,
				n2 = n2,
				r = comp.value
			})
		else
			table.insert(solver_components, {
				key = comp.key,
				raw_id = comp.raw_id,
				type = "current_source",
				n1 = n1,
				n2 = n2,
				i = comp.value
			})
		end
	end

	-- Вызов математического решателя узловых потенциалов
	local potentials = solver.solve_circuit(solver_nodes_count, solver_components)
	if not potentials then
		print("[Omic Ошибка] Схема не содержит резисторов или матрица проводимостей вырождена.")
		print("==========================================")
		return
	end

	M.circuit_results.is_solved = true
	M.circuit_results.potentials = potentials

	-- Вывод рассчитанных потенциалов всех узлов
	for node_idx = 0, solver_nodes_count do
		print(string.format("  Потенциал Узла [%d] = %.4f В", node_idx, potentials[node_idx] or 0))
	end
	print("------------------------------------------")

	-- Расчет и вывод физических величин для каждой радиодетали
	for _, comp in ipairs(solver_components) do
		local u, i = solver.get_branch_values(comp, potentials)
		local power = u * i
		rawset(M.circuit_results.branches, comp.key, {
			voltage = u,
			current = i,
			power = power,
			n1 = comp.n1,
			n2 = comp.n2
		})

		local type_label = (comp.type == "resistor") and "Резистор" or "Источник тока"
		print(string.format("  [%s %s] Узлы (%d -> %d) | U = %.3f В | I = %.3f А | P = %.3f Вт",
			type_label, comp.key, comp.n1, comp.n2, u, i, power))
	end
	print("==========================================")
end

function M.set_preview(id, start_pos, start_dir, end_pos, end_dir, color, scale)
	local key = get_id_key(id)
	rawset(M.previews, key, {
		start_pos = start_pos,
		start_dir = start_dir,
		end_pos = end_pos,
		end_dir = end_dir,
		color = color,
		scale = scale
	})
end

function M.clear_preview(id)
	local key = get_id_key(id)
	rawset(M.previews, key, nil)
end

-- Расчет контрольных точек кубической кривой Безье с плавным огибанием корпуса детали
function M.get_control_points(start_pos, start_dir, end_pos, end_dir, scale)
	scale = scale or 1.0
	local delta = end_pos - start_pos
	local dist = vmath.length(delta)
	local base_len = math.max(40.0 * scale, dist * 0.35)

	local p0 = start_pos
	local p3 = end_pos

	-- Вторая контрольная точка (выход из стартового пина)
	local p1 = p0 + start_dir * base_len
	local THRESHOLD = 0.7

	if dist > 0.1 then
		local dir_to_target = delta / dist
		local dot_start = start_dir.x * dir_to_target.x + start_dir.y * dir_to_target.y
		if dot_start < THRESHOLD then
			local normal = vmath.vector3(-start_dir.y, start_dir.x, 0)
			local cross_z = start_dir.x * dir_to_target.y - start_dir.y * dir_to_target.x
			local side = (cross_z >= 0) and 1 or -1
			local intensity = (THRESHOLD - dot_start)
			local bulge = intensity * math.min(base_len, 220.0 * scale) * 0.75
			p1 = p1 + normal * (side * bulge)
		end
	end

	-- Третья контрольная точка (вход в целевой пин или свободный конец под курсором)
	local p2
	if end_dir then
		p2 = p3 + end_dir * base_len
		if dist > 0.1 then
			local rev_delta = start_pos - end_pos
			local dir_from_target = rev_delta / dist
			local dot_end = end_dir.x * dir_from_target.x + end_dir.y * dir_from_target.y
			if dot_end < THRESHOLD then
				local normal = vmath.vector3(-end_dir.y, end_dir.x, 0)
				local cross_z = end_dir.x * dir_from_target.y - end_dir.y * dir_from_target.x
				local side = (cross_z >= 0) and 1 or -1
				local intensity = (THRESHOLD - dot_end)
				local bulge = intensity * math.min(base_len, 220.0 * scale) * 0.75
				p2 = p2 + normal * (side * bulge)
			end
		end
	else
		if dist > 0.1 then
			p2 = p3 - (delta / dist) * (base_len * 0.25)
		else
			p2 = p3
		end
	end

	return p0, p1, p2, p3
end

-- Вычисление точки на кубической кривой Безье при параметре от нуля до единицы
function M.evaluate_point(p0, p1, p2, p3, t)
	local u = 1.0 - t
	local tt = t * t
	local uu = u * u
	local uuu = uu * u
	local ttt = tt * t

	local point = uuu * p0
	point = point + (3 * uu * t) * p1
	point = point + (3 * u * tt) * p2
	point = point + ttt * p3
	return point
end

-- Запись одной вершины в потоки буфера меша
local function write_vertex(pos_stream, col_stream, v_idx, pt, z, color)
	local pi = (v_idx - 1) * 3
	pos_stream[pi + 1] = pt.x
	pos_stream[pi + 2] = pt.y
	pos_stream[pi + 3] = z

	local ci = (v_idx - 1) * 4
	col_stream[ci + 1] = color.x
	col_stream[ci + 2] = color.y
	col_stream[ci + 3] = color.z
	col_stream[ci + 4] = color.w
end

-- Построение ленты из треугольников вдоль сплайна Безье со сшиванием углов
local function append_wire_ribbon(pos_stream, col_stream, start_v_idx, start_pos, start_dir, end_pos, end_dir, color, scale, z_layer)
	local p0, p1, p2, p3 = M.get_control_points(start_pos, start_dir, end_pos, end_dir, scale)
	local half_thick = math.max(2.0, (M.THICKNESS * scale) * 0.5)

	-- Вычисляем опорные точки кривой
	local pts = {}
	for i = 0, M.SEGMENTS do
		local t = i / M.SEGMENTS
		pts[i] = M.evaluate_point(p0, p1, p2, p3, t)
	end

	-- Вычисляем нормализованные векторы направлений каждого сегмента
	local seg_dirs = {}
	for i = 0, M.SEGMENTS - 1 do
		local diff = pts[i + 1] - pts[i]
		local len = vmath.length(diff)
		if len > 0.0001 then
			seg_dirs[i] = diff / len
		else
			seg_dirs[i] = start_dir
		end
	end

	-- Строим левый и правый края ленты
	local left_pts = {}
	local right_pts = {}
	for i = 0, M.SEGMENTS do
		local pt = pts[i]
		local normal
		if i == 0 then
			-- В начале перпендикуляр строго к направлению выхода пина
			normal = vmath.vector3(-start_dir.y, start_dir.x, 0)
		elseif i == M.SEGMENTS then
			-- В конце перпендикуляр к направлению входа в целевой пин
			local end_fwd = end_dir and vmath.vector3(-end_dir.x, -end_dir.y, 0) or seg_dirs[M.SEGMENTS - 1]
			normal = vmath.vector3(-end_fwd.y, end_fwd.x, 0)
		else
			-- На стыках сегментов усредняем касательную без разрывов
			local d_prev = seg_dirs[i - 1]
			local d_next = seg_dirs[i]
			local avg_dir = d_prev + d_next
			local avg_len = vmath.length(avg_dir)
			if avg_len > 0.0001 then
				avg_dir = avg_dir / avg_len
			else
				avg_dir = d_next
			end
			normal = vmath.vector3(-avg_dir.y, avg_dir.x, 0)
		end

		left_pts[i] = pt + normal * half_thick
		right_pts[i] = pt - normal * half_thick
	end

	-- Заполняем треугольники между соседними сечениями
	local v = start_v_idx
	for i = 0, M.SEGMENTS - 1 do
		local l0 = left_pts[i]
		local r0 = right_pts[i]
		local l1 = left_pts[i + 1]
		local r1 = right_pts[i + 1]

		write_vertex(pos_stream, col_stream, v,     l0, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 1, r0, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 2, l1, z_layer, color)

		write_vertex(pos_stream, col_stream, v + 3, r0, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 4, r1, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 5, l1, z_layer, color)

		write_vertex(pos_stream, col_stream, v + 6,  l0, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 7,  l1, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 8,  r0, z_layer, color)

		write_vertex(pos_stream, col_stream, v + 9,  r0, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 10, l1, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 11, r1, z_layer, color)

		v = v + 12
	end

	return v
end

-- Отрисовка всех проводов, предпросмотра и отладочной информации на проводах
function M.render_all(wire_color, caller_id)
	local caller_key = caller_id and get_id_key(caller_id) or M.master_key
	local is_master_call = (caller_key == M.master_key)

	local valid_connections = {}
	for idx, conn in ipairs(M.connections) do
		local from_comp = M.pins[conn.from_key]
		local to_comp = M.pins[conn.to_key]
		if from_comp and to_comp then
			local avg_scale = ((from_comp.scale or 1.0) + (to_comp.scale or 1.0)) * 0.5
			table.insert(valid_connections, {
				wire_idx = idx,
				from_key = conn.from_key,
				from_pin = conn.from_pin,
				to_key = conn.to_key,
				to_pin = conn.to_pin,
				start_pos = from_comp[conn.from_pin].pos,
				start_dir = from_comp[conn.from_pin].dir,
				end_pos = to_comp[conn.to_pin].pos,
				end_dir = to_comp[conn.to_pin].dir,
				scale = avg_scale
			})
		end
	end

	-- Вывод отладочного текста посередине каждого провода ровно один раз за кадр
	if is_master_call then
		for _, wc in ipairs(valid_connections) do
			local p0, p1, p2, p3 = M.get_control_points(wc.start_pos, wc.start_dir, wc.end_pos, wc.end_dir, wc.scale)
			local mid_pt = M.evaluate_point(p0, p1, p2, p3, 0.5)
			local pin_key = get_pin_key(wc.from_key, wc.from_pin)
			local node_id = M.circuit_results.pin_nodes[pin_key]

			local wire_info
			if M.circuit_results.is_solved and node_id ~= nil and M.circuit_results.potentials[node_id] ~= nil then
				local phi = M.circuit_results.potentials[node_id]
				wire_info = string.format("W#%d [Node %d] Phi=%.2fV", wc.wire_idx, node_id, phi)
			else
				wire_info = string.format("W#%d [Node %s] (Open)", wc.wire_idx, tostring(node_id or "?"))
			end

			msg.post("@render:", "draw_text", {
				text = wire_info,
				position = M.world_to_screen(mid_pt.x - 45, mid_pt.y + 10)
			})
		end
	end

	local active_previews = {}
	for _, prev in pairs(M.previews) do
		table.insert(active_previews, prev)
	end

	local total_wires = #valid_connections + #active_previews
	if total_wires == 0 then
		if M.mesh_id then
			msg.post(M.mesh_id, "disable")
		end
		return
	end

	if not M.mesh_id then
		M.mesh_id = factory.create("/wire_manager#factory", vmath.vector3(0, 0, 0), vmath.quat(), {}, vmath.vector3(1, 1, 1))
		msg.post(M.mesh_id, "set_parent", { parent_id = hash("/board"), keep_world_transform = 0 })
	end

	msg.post(M.mesh_id, "enable")
	go.set_position(vmath.vector3(0, 0, 0), M.mesh_id)
	go.set_scale(vmath.vector3(1, 1, 1), M.mesh_id)

	local needed_vertices = total_wires * M.SEGMENTS * 12
	if not M.buf or M.buf_vertex_count ~= needed_vertices then
		M.buf = buffer.create(needed_vertices, {
			{ name = hash("position"), type = buffer.VALUE_TYPE_FLOAT32, count = 3 },
			{ name = hash("color"),    type = buffer.VALUE_TYPE_FLOAT32, count = 4 }
		})
		M.buf_vertex_count = needed_vertices
	end

	local pos_stream = buffer.get_stream(M.buf, hash("position"))
	local col_stream = buffer.get_stream(M.buf, hash("color"))

	local v_idx = 1
	for _, wc in ipairs(valid_connections) do
		v_idx = append_wire_ribbon(pos_stream, col_stream, v_idx, wc.start_pos, wc.start_dir, wc.end_pos, wc.end_dir, wire_color, wc.scale, 0.02)
	end
	for _, prev in ipairs(active_previews) do
		v_idx = append_wire_ribbon(pos_stream, col_stream, v_idx, prev.start_pos, prev.start_dir, prev.end_pos, prev.end_dir, prev.color, prev.scale, 0.03)
	end

	-- Передаем обновленный буфер в ресурс меша
	local mesh_url = msg.url(nil, M.mesh_id, "mesh")
	local res = go.get(mesh_url, "vertices")
	---@cast res hash
	resource.set_buffer(res, M.buf)
end

return M