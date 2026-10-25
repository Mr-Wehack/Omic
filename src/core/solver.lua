local matrix = require("src.core.matrix")

local M = {}

--- Решает электрическую цепь, состоящую из резисторов и узлов
-- @param nodes_count integer: количество узлов (исключая базовый узел 0)
-- @param components table: список элементов схемы
--        Каждый элемент резистора: { type = "resistor", n1 = 1, n2 = 2, r = 100 }
--        Каждый элемент источника тока: { type = "current_source", n1 = 1, n2 = 2, i = 0.5 } (от n1 к n2)
-- @return table|nil: таблица потенциалов узлов { [0] = 0, [1] = phi1, ... }, либо nil при ошибке
function M.solve_circuit(nodes_count, components)
	if nodes_count < 1 then
		return { [0] = 0 }
	end

	-- Инициализируем матрицу проводимостей A (nodes_count x nodes_count)
	local a = {}
	for i = 1, nodes_count do
		a[i] = {}
		for j = 1, nodes_count do
			a[i][j] = 0
		end
	end

	-- Инициализируем вектор токов B
	local b = {}
	for i = 1, nodes_count do
		b[i] = 0
	end

	-- Заполнение проводимостей и токов
	for _, comp in ipairs(components) do
		if comp.type == "resistor" then
			local g = 1 / comp.r
			local u = comp.n1
			local v = comp.n2

			-- Добавляем проводимость в диагональные элементы узлов (если это не опорная земля 0)
			if u > 0 then
				a[u][u] = a[u][u] + g
			end
			if v > 0 then
				a[v][v] = a[v][v] + g
			end

			-- Внедиагональные связи между независимыми узлами
			if u > 0 and v > 0 then
				a[u][v] = a[u][v] - g
				a[v][u] = a[v][u] - g
			end

		elseif comp.type == "current_source" then
			-- Источник направлен от n1 к n2: из n1 вытекает (-I), в n2 втекает (+I)
			if comp.n1 > 0 then
				b[comp.n1] = b[comp.n1] - comp.i
			end
			if comp.n2 > 0 then
				b[comp.n2] = b[comp.n2] + comp.i
			end
		end
	end

	-- Находим потенциалы методом Крамера
	local solution = matrix.solve_cramer(a, b)
	if not solution then
		return nil
	end

	-- Формируем результат, где узел 0 всегда имеет потенциал 0 В
	local potentials = { [0] = 0 }
	for i = 1, nodes_count do
		potentials[i] = solution[i]
	end

	return potentials
end

--- Рассчитывает напряжение и ток для конкретного двухполюсника
-- @param comp table: элемент цепи
-- @param potentials table: вычисленные потенциалы узлов
-- @return number, number: напряжение (В) и ток (А)
function M.get_branch_values(comp, potentials)
	local v1 = potentials[comp.n1] or 0
	local v2 = potentials[comp.n2] or 0
	local voltage = math.abs(v1 - v2)
	local current = 0

	if comp.type == "resistor" and comp.r > 0 then
		current = voltage / comp.r
	elseif comp.type == "current_source" then
		current = comp.i
	end

	return voltage, current
end

return M