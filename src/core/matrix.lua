-- src/core/matrix.lua
-- Решение СЛАУ методом определителей Крамера. Вскоре он будет заменен на метод Гауса, который будет работать намного быстрее для сложных схем. Потом его можно заменить на еще более быстрый метод, такой как разреженное LU-разложение (Sparse LU / алгоритм KLU).

local M = {}

-- Создает минор матрицы (вычеркивает строку row_to_remove и столбец col_to_remove)
local function get_minor(m, row_to_remove, col_to_remove)
	local minor = {}
	local n = #m
	for i = 1, n do
		if i ~= row_to_remove then
			local new_row = {}
			for j = 1, n do
				if j ~= col_to_remove then
					table.insert(new_row, m[i][j])
				end
			end
			table.insert(minor, new_row)
		end
	end
	return minor
end

-- Вычисляет определитель матрицы разложением по первой строке по теореме Лапласа
function M.determinant(m)
	local n = #m
	if n == 1 then
		return m[1][1]
	elseif n == 2 then
		return m[1][1] * m[2][2] - m[1][2] * m[2][1]
	end

	local det = 0.0
	for j = 1, n do
		local sign = (-1) ^ (j + 1)
		local minor = get_minor(m, 1, j)
		det = det + sign * m[1][j] * M.determinant(minor)
	end
	return det
end

-- Решает систему A * x = B методом Крамера
function M.solve_cramer(a, b)
	local n = #b
	local delta = M.determinant(a)
	if math.abs(delta) < 0.00000000000001 then
		return nil -- Определитель равен нулю: цепь разомкнута или КЗ
	end

	local x = {}
	for i = 1, n do
		local a_copy = {}
		for row = 1, n do
			a_copy[row] = {}
			for col = 1, n do
				if col == i then
					a_copy[row][col] = b[row]
				else
					a_copy[row][col] = a[row][col]
				end
			end
		end

		local delta_i = M.determinant(a_copy)
		x[i] = delta_i / delta
	end

	return x
end

return M
