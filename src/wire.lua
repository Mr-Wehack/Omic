-- Модуль для управления соединениями на плате и построения гладких полигональных проводов (Mesh)
local M = {}

-- НАСТРОЙКИ ПРОВОДОВ
M.THICKNESS = 10.0 -- Базовая толщина изогнутого провода в пикселях (масштабируется под деталь)
M.SEGMENTS = 64    -- Количество продольных делений кривой Безье (чем больше, тем плавнее дуга)

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
				local dist = vmath.length(vmath.vector3(pins_data[pin_idx].pos.x, pins_data[pin_idx].pos.y, 0) - m_pos)
				if dist <= hit_radius then
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

-- Вычисляет 4 опорные точки кубической кривой Безье с ПЛАВНЫМ ОБХОДОМ от 45 до 180 градусов
function M.get_control_points(start_pos, start_dir, end_pos, end_dir, scale)
	scale = scale or 1.0
	local delta = end_pos - start_pos
	local dist = vmath.length(delta)

	-- Базовая сила выталкивания провода из торца детали (зависит от расстояния и масштаба)
	local base_len = math.max(30 * scale, math.min(dist * 0.5, 150 * scale))

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
			local bulge = intensity * base_len * 0.8
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
				local bulge = intensity * base_len * 0.8
				p2 = p2 + normal * (side * bulge)
			end
		end
	else
		-- Если конец провода еще тянется в воздухе за мышкой, вторая контрольная точка равна концу
		p2 = p3
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

	-- Математическая формула кубической кривой Безье
	local point = uuu * p0
	point = point + (3 * uu * t) * p1
	point = point + (3 * u * tt) * p2
	point = point + ttt * p3
	return point
end

-- Вычисляет единичный вектор касательной (направление движения провода) в точке t (от 0.0 до 1.0)
function M.evaluate_tangent(p0, p1, p2, p3, t)
	local u = 1.0 - t
	-- Производная кубической кривой Безье
	local d0 = (3 * u * u) * (p1 - p0)
	local d1 = (6 * u * t) * (p2 - p1)
	local d2 = (3 * t * t) * (p3 - p2)
	local tan = d0 + d1 + d2
	local len = vmath.length(tan)
	if len < 0.0001 then
		return vmath.vector3(1, 0, 0)
	end
	return tan / len
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

-- Генерирует непрерывную двустороннюю ленту из треугольников для одного провода и прижимает его торцы к резисторам
local function append_wire_ribbon(pos_stream, col_stream, start_v_idx, start_pos, start_dir, end_pos, end_dir, color, scale, z_layer)
	local p0, p1, p2, p3 = M.get_control_points(start_pos, start_dir, end_pos, end_dir, scale)
	local half_thick = math.max(2.0, (M.THICKNESS * scale) * 0.5)

	-- Массивы левых и правых краев ленты вдоль всей кривой (от 0 до M.SEGMENTS)
	local left_pts = {}
	local right_pts = {}

	for i = 0, M.SEGMENTS do
		local t = i / M.SEGMENTS
		local pt = M.evaluate_point(p0, p1, p2, p3, t)
		local fwd

		if i == 0 then
			-- В самом начале (i = 0) принудительно берем вектор выхода из резистора start_dir!
			-- Благодаря этому стартовая грань провода (L0..R0) ложится СТРОГО вдоль боковой грани первого резистора
			fwd = start_dir
		elseif i == M.SEGMENTS and end_dir ~= nil then
			-- В самом конце (i = N), если провод прикреплен к пину, берем вектор входа (-end_dir)!
			-- Благодаря этому конечная грань провода (LN..RN) ложится СТРОГО вдоль боковой грани второго резистора
			fwd = vmath.vector3(-end_dir.x, -end_dir.y, 0)
		else
			-- На всех промежуточных участках берем гладкую касательную кривой Безье
			fwd = M.evaluate_tangent(p0, p1, p2, p3, t)
		end

		-- Перпендикуляр (нормаль) к направлению провода для откладывания полуширины влево и вправо
		local normal = vmath.vector3(-fwd.y, fwd.x, 0)
		local l_pt = pt + normal * half_thick
		local r_pt = pt - normal * half_thick

		-- Защита от захода углов провода внутрь корпуса первого резистора при резком изгибе на старте
		if i > 0 and i <= 4 then
			local dot_l = (l_pt.x - p0.x) * start_dir.x + (l_pt.y - p0.y) * start_dir.y
			if dot_l < 0 then l_pt = l_pt - start_dir * dot_l end
			local dot_r = (r_pt.x - p0.x) * start_dir.x + (r_pt.y - p0.y) * start_dir.y
			if dot_r < 0 then r_pt = r_pt - start_dir * dot_r end
		end

		-- Защита от захода углов провода внутрь корпуса второго резистора при резком изгибе на входе
		if end_dir ~= nil and i >= (M.SEGMENTS - 4) and i < M.SEGMENTS then
			local dot_l = (l_pt.x - p3.x) * end_dir.x + (l_pt.y - p3.y) * end_dir.y
			if dot_l < 0 then l_pt = l_pt - end_dir * dot_l end
			local dot_r = (r_pt.x - p3.x) * end_dir.x + (r_pt.y - p3.y) * end_dir.y
			if dot_r < 0 then r_pt = r_pt - end_dir * dot_r end
		end

		left_pts[i] = l_pt
		right_pts[i] = r_pt
	end

	-- Сшиваем соседние сечения i и (i + 1) треугольниками с ОБЩИМИ вершинами в обе стороны обхода (CCW и CW),
	-- чтобы видеокарта не отсекала грани (Backface Culling) при любом направлении изгиба
	local v = start_v_idx
	for i = 0, M.SEGMENTS - 1 do
		local l0 = left_pts[i]
		local r0 = right_pts[i]
		local l1 = left_pts[i + 1]
		local r1 = right_pts[i + 1]

		-- Лицевая сторона (Против часовой стрелки - CCW)
		write_vertex(pos_stream, col_stream, v,     l0, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 1, r0, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 2, l1, z_layer, color)

		write_vertex(pos_stream, col_stream, v + 3, r0, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 4, r1, z_layer, color)
		write_vertex(pos_stream, col_stream, v + 5, l1, z_layer, color)

		-- Обратная сторона (По часовой стрелке - CW, защита от отсечения граней)
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
	-- 1. Считаем общее количество активных проводов (завершенные + протягиваемые превью)
	local valid_connections = {}
	for _, conn in ipairs(M.connections) do
		local from_comp = M.pins[conn.from_id]
		local to_comp = M.pins[conn.to_id]
		if from_comp and to_comp then
			table.insert(valid_connections, {
				start_pos = from_comp[conn.from_pin].pos,
				start_dir = from_comp[conn.from_pin].dir,
				end_pos = to_comp[conn.to_pin].pos,
				end_dir = to_comp[conn.to_pin].dir,
				scale = from_comp.scale or 1.0
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

	-- Создаем объект меша через фабрику один раз при первом появлении провода
	if not M.mesh_id then
		M.mesh_id = factory.create("/wire_manager#factory", vmath.vector3(0, 0, 0))
	end
	msg.post(M.mesh_id, "enable")

	-- Каждому проводу нужно M.SEGMENTS * 12 вершин (по 4 треугольника на сегмент для двусторонней видимости)
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

	-- 2. Записываем в буфер все завершенные провода (на слое Z = 0.02)
	for _, wc in ipairs(valid_connections) do
		v_idx = append_wire_ribbon(
			pos_stream, col_stream, v_idx,
			wc.start_pos, wc.start_dir, wc.end_pos, wc.end_dir,
			wire_color, wc.scale, 0.02
		)
	end

	-- 3. Записываем в буфер все полупрозрачные превью-провода (чуть выше, на слое Z = 0.03)
	for _, prev in ipairs(active_previews) do
		v_idx = append_wire_ribbon(
			pos_stream, col_stream, v_idx,
			prev.start_pos, prev.start_dir, prev.end_pos, prev.end_dir,
			prev.color, prev.scale, 0.03
		)
	end

	-- Передаем обновленный буфер вершин в компонент #mesh
	local mesh_url = msg.url(nil, M.mesh_id, "mesh")
	local res = go.get(mesh_url, "vertices")
	---@cast res hash
	resource.set_buffer(res, M.buf)
end

return M