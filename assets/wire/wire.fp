#version 140

in vec4 var_color;
out vec4 out_fragColor;

void main()
{
	// Предумноженная альфа для чистой полупрозрачности в 2D-слое Defold
	out_fragColor = vec4(var_color.rgb * var_color.a, var_color.a);
}