-- Модуль для управления соединениями на плате и построения гладких полигональных проводов (Mesh)
local M = {}

-- НАСТРОЙКИ ПРОВОДОВ
M.THICKNESS = 10.0 -- Базовая толщина изогнутого провода в пикселях (масштабируется под деталь)
M.SEGMENTS = 48    -- Количество продольных делений кривой Безье (48 гарантирует плавность даже на огромных дистанциях)

-- Палитра цветов для проводов в зависимости от выбранной темы
-- У preview включена настоящая полупрозрачность (alpha = 0.55), так как в Mesh нет наложений сегментов!
M.THEME_COLORS = {
	dark = {
		wire = vmath.vector4(0.25, 0.65, 0.95, 1.0),     -- Сплошной голубой провод (темная тема)
		preview = vmath.vector4(0.45, 0.80, 1.0, 0.55)   -- Полупрозрачный провод при протяжке мышкой
	},
	light = {
		wire = vmath.vector4(0.10, 0.40, 0.75, 1.0),     -- Сплошной темно-синий провод (светлая тема)
		preview = vmath.vector4(0.10, 0.40, 0.75, 0.50)  -- Полупрозрачный темно-синий при протяжке мышкой
	}
}

-- ГЛОБАЛЬНЫЕ ДАННЫЕ ЦЕПИ
-- Реестр координат всех пинов. Формат: [id_объекта] = { scale = s, [1] = {pos, dir}, [2] = {pos, dir} }
M.pins = {}
-- Список всех завершенных соединений. Формат: { {from_id, from_pin, to_id, to_pin} }
M.connections = {}
-- Активные превью-провода (когда игрок тянет провод мышкой). Формат: [id_объекта] = { ... }
M.previews = {}

-- ID единственного игрового объекта с компонентом #mesh, который рисует все провода сразу за 1 вызов GPU
M.mesh_id = nil
-- Текущий буфер вершин и его емкость
M.buf = nil
M.buf_vertex_count = 0

-- Функция регистрации: каждый компонент вызывает её каждый кадр,
-- чтобы сообщить модулю проводов свои актуальные мировые координаты пинов на торцах корпуса
function M.register_pins(id, p1_pos, p1_dir, p2_pos, p2_dir, scale)
	M.pins[id] = {
		scale = scale or 1.0,
		[1] = { pos = p1_pos, dir = p1_dir },
		[2] = { pos = p2_pos, dir = p2_dir }
	}
end

-- Функция поиска: ищет любой пин ЛЮБОГО компонента в заданном радиусе от курсора мыши
-- Возвращает ID найденного компонента и номер пина (1 или 2), либо nil, если рядом пусто
function M.find_closest_pin(mouse_x, mouse_y, hit_radius, ignore_id, ignore_pin)
	local m_pos = vmath.vector3(mouse_x, mouse_y, 0)
	for id, pins_data in pairs(M.pins) do
		for pin_idx = 1, 2 do
			-- Пропускаем стартовый пин, из которого сами же и тянем провод
			if not (id == ignore_id and pin_idx == ignore_pin) then
				-- Радиус захвата учитывает собственный масштаб целевого компонента
				local target_radius = math.max(hit_radius, 35.0 * (pins_data.scale or 1.0))
				local dist = vmath.length(vmath.vector3(pins_data[pin_idx].pos.x, pins_data[pin_idx].pos.y, 0) - m_pos)
				if dist <= target_radius then
					return id, pin_idx
				end
			end
		end
	end
	return nil, nil
end

-- Функция соединения: создает неразрывную связь между двумя пинами компонентов
function M.connect(from_id, from_pin, to_id, to_pin)
	-- Защита: нельзя подключить провод из детали в ту же самую деталь на тот же пин
	if from_id == to_id and from_pin == to_pin then return end
	table.insert(M.connections, {
		from_id = from_id,
		from_pin = from_pin,
		to_id = to_id,
		to_pin = to_pin
	})
end

-- Сохраняет состояние протягиваемого за мышкой превью-провода для конкретного компонента
function M.set_preview(id, start_pos, start_dir, end_pos, end_dir, color, scale)
	M.previews[id] = {
		start_pos = start_pos,
		start_dir = start_dir,
		end_pos = end_pos,
		end_dir = end_dir,
		color = color,
		scale = scale
	}
end

-- Очищает превью-провод, когда игрок отпускает кнопку мыши
function M.clear_preview(id)
	M.previews[id] = nil
end

-- Вычисляет 4 опорные точки кубической кривой Безье с ПЛАВНЫМ ОБХОДОМ без схлопывания на больших дистанциях
function M.get_control_points(start_pos, start_dir, end_pos, end_dir, scale)
	scale = scale or 1.0
	local delta = end_pos - start_pos
	local dist = vmath.length(delta)

	-- Длина рычага Безье всегда пропорциональна расстоянию (35% от дистанции, но не меньше 40 * scale).
	local base_len = math.max(40.0 * scale, dist * 0.35)

	-- Точки начала (P0) и конца (P3) провода строго зафиксированы на торцах резистора
	local p0 = start_pos
	local p3 = end_pos

	-- 1. Считаем P1 (контрольная точка выхода провода из первого компонента)
	local p1 = p0 + start_dir * base_len

	-- Порог начала бокового увода кривой: 0.7 соответствует углу ~45 градусов
	local THRESHOLD = 0.7

	if dist > 0.1 then
		local dir_to_target = delta / dist
		-- Скалярное произведение показывает косинус угла между направлением выхода и целью
		local dot_start = start_dir.x * dir_to_target.x + start_dir.y * dir_to_target.y

		if dot_start < THRESHOLD then
			-- Вектор перпендикуляра (нормаль) для увода провода вбок вокруг корпуса
			local normal = vmath.vector3(-start_dir.y, start_dir.x, 0)
			-- Векторное произведение определяет сторону обхода (слева или справа)
			local cross_z = start_dir.x * dir_to_target.y - start_dir.y * dir_to_target.x
			local side = (cross_z >= 0) and 1 or -1

			-- Плавное нарастание дуги обхода от 45 до 180 градусов
			local intensity = (THRESHOLD - dot_start)
			local bulge = intensity * math.min(base_len, 220.0 * scale) * 0.75
			p1 = p1 + normal * (side * bulge)
		end
	end

	-- 2. Считаем P2 (контрольная точка входа провода во второй компонент)
	local p2
	if end_dir then
		p2 = p3 + end_dir * base_len
		if dist > 0.1 then
			-- Вычисляем обратный вектор через вычитание (start_pos - end_pos) без унарного минуса
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
		-- Если конец провода еще тянется в воздухе за мышкой, формируем мягкий подход к курсору
		if dist > 0.1 then
			p2 = p3 - (delta / dist) * (base_len * 0.25)
		else
			p2 = p3
		end
	end

	return p0, p1, p2, p3
end

-- Возвращает координаты точки на изогнутом проводе при параметре t (от 0.0 до 1.0)
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

-- Вспомогательная функция: записывает одну вершину (позицию и цвет) в потоки буфера Mesh
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

-- Генерирует непрерывную двустороннюю ленту из треугольников без схлопывания на крутых поворотах
local function append_wire_ribbon(pos_stream, col_stream, start_v_idx, start_pos, start_dir, end_pos, end_dir, color, scale, z_layer)
	local p0, p1, p2, p3 = M.get_control_points(start_pos, start_dir, end_pos, end_dir, scale)
	local half_thick = math.max(2.0, (M.THICKNESS * scale) * 0.5)

	-- 1. Сначала вычисляем все опорные точки центральной линии кривой
	local pts = {}
	for i = 0, M.SEGMENTS do
		local t = i / M.SEGMENTS
		pts[i] = M.evaluate_point(p0, p1, p2, p3, t)
	end

	-- 2. Вычисляем единичные направления каждого хордового сегмента
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

	-- Массивы левых и правых краев ленты вдоль всей кривой (от 0 до M.SEGMENTS)
	local left_pts = {}
	local right_pts = {}

	for i = 0, M.SEGMENTS do
		local pt = pts[i]
		local normal

		if i == 0 then
			-- В самом начале (i = 0) грань провода жестко параллельна боковому срезу первого резистора!
			normal = vmath.vector3(-start_dir.y, start_dir.x, 0)
		elseif i == M.SEGMENTS then
			-- В самом конце (i = N) грань жестко параллельна боковому срезу второго резистора
			local end_fwd = end_dir and vmath.vector3(-end_dir.x, -end_dir.y, 0) or seg_dirs[M.SEGMENTS - 1]
			normal = vmath.vector3(-end_fwd.y, end_fwd.x, 0)
		else
			-- На всех внутренних стыках вычисляем биссектрису (Miter-нормаль)
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

	-- Сшиваем соседние сечения i и (i + 1) треугольниками с ОБЩИМИ вершинами в обе стороны обхода
	local v = start_v_idx
	for i = 0, M.SEGMENTS - 1 do
		local l0 = left_pts[i]
		local r0 = right_pts[i]
		local l1 = left_pts[i + 1]
		local r1 = right_pts[i + 1]

		-- Лицевая сторона
		write_vertex(pos_stream, col_stream, v,     l0, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 1, r0, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 2, l1, z_layer, color)

		write_vertex(pos_stream, col_stream, v + 3, r0, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 4, r1, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 5, l1, z_layer, color)

		-- Обратная сторона (защита от отсечения граней)
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

-- Главная функция отрисовки всех проводов и превью в единый Mesh-компонент
function M.render_all(wire_color)
	local valid_connections = {}
	for _, conn in ipairs(M.connections) do
		local from_comp = M.pins[conn.from_id]
		local to_comp = M.pins[conn.to_id]
		if from_comp and to_comp then
			local avg_scale = ((from_comp.scale or 1.0) + (to_comp.scale or 1.0)) * 0.5
			table.insert(valid_connections, {
				start_pos = from_comp[conn.from_pin].pos,
				start_dir = from_comp[conn.from_pin].dir,
				end_pos = to_comp[conn.to_pin].pos,
				end_dir = to_comp[conn.to_pin].dir,
				scale = avg_scale
			})
		end
	end

	local active_previews = {}
	for _, prev in pairs(M.previews) do
		table.insert(active_previews, prev)
	end

	local total_wires = #valid_connections + #active_previews

	-- Если на экране нет ни одного провода — скрываем меш и выходим
	if total_wires == 0 then
		if M.mesh_id then
			msg.post(M.mesh_id, "disable")
		end
		return
	end

	-- Создаем объект меша через фабрику один раз
	if not M.mesh_id then
		M.mesh_id = factory.create("/wire_manager#factory", vmath.vector3(0, 0, 0), vmath.quat(), {}, vmath.vector3(1, 1, 1))
		-- Привязываем меш проводов к доске, чтобы он двигался и масштабировался вместе с ней!
		msg.post(M.mesh_id, "set_parent", { parent_id = hash("/board"), keep_world_transform = 0 })
	end

	msg.post(M.mesh_id, "enable")
	go.set_position(vmath.vector3(0, 0, 0), M.mesh_id)
	go.set_scale(vmath.vector3(1, 1, 1), M.mesh_id)

	-- Каждому проводу нужно M.SEGMENTS * 12 вершин
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

	-- Записываем в буфер все завершенные провода
	for _, wc in ipairs(valid_connections) do
		v_idx = append_wire_ribbon(pos_stream, col_stream, v_idx, wc.start_pos, wc.start_dir, wc.end_pos, wc.end_dir, wire_color, wc.scale, 0.02)
	end

	-- Записываем в буфер все превью-провода
	for _, prev in ipairs(active_previews) do
		v_idx = append_wire_ribbon(pos_stream, col_stream, v_idx, prev.start_pos, prev.start_dir, prev.end_pos, prev.end_dir, prev.color, prev.scale, 0.03)
	end

	-- Передаем обновленный буфер вершин в компонент #mesh
	local mesh_url = msg.url(nil, M.mesh_id, "mesh")
	local res = go.get(mesh_url, "vertices")
	---@cast res hash
	resource.set_buffer(res, M.buf)
end

return M