// Aul design tokens — mirrors /docs/design-tokens.json (the single source of
// truth). Kept in sync by hand; the values also feed Tailwind via @theme in
// index.css. "Family hearth + engineering honesty."

export const colors = {
  light: {
    bg: '#FAF7F2',
    surface: '#FFFFFF',
    primary: '#155E4A',
    primaryHover: '#0F4536',
    text: '#1C1917',
    textSecondary: '#78716C',
    accent: '#F59E0B',
    danger: '#DC2626',
    success: '#16A34A',
    border: '#E7E5E4',
  },
  dark: {
    bg: '#131211',
    surface: '#1C1A19',
    primary: '#34D399',
    primaryHover: '#2BBE86',
    text: '#FAF7F2',
    textSecondary: '#A8A29E',
    accent: '#F59E0B',
    danger: '#F87171',
    success: '#4ADE80',
    border: '#2A2725',
  },
} as const;

export const motion = {
  durationMs: 250,
  easing: 'cubic-bezier(0.2, 0.8, 0.2, 1)',
  markerInterpolateMs: 1000,
} as const;

/// Battery ring color: amber when low, primary otherwise.
export function batteryColor(pct: number | null | undefined): string {
  if (pct == null) return colors.light.textSecondary;
  if (pct <= 15) return colors.light.danger;
  if (pct <= 30) return colors.light.accent;
  return colors.light.primary;
}
