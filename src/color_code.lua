local M = {}

-- Палитра цветов по стандарту IEC 60062 (RGBA)
M.COLORS = {
	black  = vmath.vector4(0.10, 0.10, 0.10, 1.0), -- 0
	brown  = vmath.vector4(0.55, 0.27, 0.07, 1.0), -- 1 (допуск ±1%)
	red    = vmath.vector4(0.85, 0.15, 0.15, 1.0), -- 2 (допуск ±2%)
	orange = vmath.vector4(0.95, 0.50, 0.10, 1.0), -- 3
	yellow = vmath.vector4(0.95, 0.85, 0.10, 1.0), -- 4
	green  = vmath.vector4(0.15, 0.70, 0.20, 1.0), -- 5 (допуск ±0.5%)
	blue   = vmath.vector4(0.15, 0.35, 0.85, 1.0), -- 6 (допуск ±0.25%)
	violet = vmath.vector4(0.60, 0.20, 0.80, 1.0), -- 7 (допуск ±0.1%)
	grey   = vmath.vector4(0.50, 0.50, 0.52, 1.0), -- 8
	white  = vmath.vector4(0.95, 0.95, 0.95, 1.0), -- 9
	gold   = vmath.vector4(0.85, 0.65, 0.13, 1.0), -- множитель 0.1 (допуск ±5%)
	silver = vmath.vector4(0.75, 0.75, 0.78, 1.0)  -- множитель 0.01 (допуск ±10%)
}

-- Соответствие цифры (0..9) и степени множителя (-2..9) имени цвета
local DIGIT_TO_NAME = {
	[0] = "black", [1] = "brown", [2] = "red",    [3] = "orange", [4] = "yellow",
	[5] = "green", [6] = "blue",  [7] = "violet", [8] = "grey",   [9] = "white",
	[-1] = "gold", [-2] = "silver"
}

local NAME_TO_DIGIT = {}
for k, v in pairs(DIGIT_TO_NAME) do
	NAME_TO_DIGIT[v] = k
end

-- Перевод сопротивления (Ом) -> 5 полосок
-- Возвращает массив из 5 таблиц: { name = "red", color = vector4(...) }
function M.ohms_to_bands(ohms, tolerance_name)
	tolerance_name = tolerance_name or "brown" -- по умолчанию ±1%

	if ohms <= 0 then
		local blk = { name = "black", color = M.COLORS.black }
		return { blk, blk, blk, blk, { name = tolerance_name, color = M.COLORS[tolerance_name] } }
	end

	-- Приводим число к виду трехзначной мантиссы (от 100 до 999)
	local exp = math.floor(math.log10(ohms)) - 2
	local normalized = math.floor((ohms / (10 ^ exp)) + 0.5)

	-- Если из-за округления получилось 1000, сдвигаем разряд
	if normalized >= 1000 then
		normalized = math.floor(normalized / 10)
		exp = exp + 1
	end

	local d1 = math.floor(normalized / 100) % 10
	local d2 = math.floor(normalized / 10) % 10
	local d3 = normalized % 10

	-- Зажимаем множитель в допустимых пределах стандарта (-2 .. 9)
	exp = math.max(-2, math.min(9, exp))

	local n1 = DIGIT_TO_NAME[d1]
	local n2 = DIGIT_TO_NAME[d2]
	local n3 = DIGIT_TO_NAME[d3]
	local n4 = DIGIT_TO_NAME[exp]

	return {
		{ name = n1, color = M.COLORS[n1], value = d1 },
		{ name = n2, color = M.COLORS[n2], value = d2 },
		{ name = n3, color = M.COLORS[n3], value = d3 },
		{ name = n4, color = M.COLORS[n4], value = exp },
		{ name = tolerance_name, color = M.COLORS[tolerance_name] }
	}
end

-- Обратный перевод: 5 имен цветов -> сопротивление в Омах
-- Пример вызова: color_code.bands_to_ohms({"brown", "black", "black", "brown", "brown"}) -> 1000 Ом
function M.bands_to_ohms(band_names)
	local d1 = NAME_TO_DIGIT[band_names[1]] or 0
	local d2 = NAME_TO_DIGIT[band_names[2]] or 0
	local d3 = NAME_TO_DIGIT[band_names[3]] or 0
	local exp = NAME_TO_DIGIT[band_names[4]] or 0

	local base = (d1 * 100) + (d2 * 10) + d3
	return base * (10 ^ exp)
end

return M