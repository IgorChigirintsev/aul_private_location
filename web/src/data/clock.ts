import { useEffect, useState } from 'react';

/// Re-renders the caller on an interval and hands back `Date.now()`, so a
/// countdown ticks without every parent re-rendering with it. Keep the callers
/// small and leaf-ish — this fires once a second by default.
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), intervalMs);
    return () => window.clearInterval(id);
  }, [intervalMs]);
  return now;
}
