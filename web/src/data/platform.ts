/// What platform string this browser registers as. A phone opened in a mobile
/// browser is NOT a "PC": tagging it as such put a "PC" badge on phones on the
/// map and offered them the desktop-only "located via Wi-Fi" hint (a phone has
/// GPS). Registering mobile browsers as 'web-mobile' — distinct from desktop
/// 'web' — lets the existing `platform === 'web'` checks stay correct: desktop
/// keeps its badge, phones drop it, exactly like the native app.
///
/// The distinction lives only in the platform string; the server accepts both
/// values and nothing else about the device changes.
export function detectPlatform(): 'web' | 'web-mobile' {
  return isMobileBrowser() ? 'web-mobile' : 'web';
}

/// Prefer the structured, spoof-resistant hint (`navigator.userAgentData.mobile`),
/// which Chromium exposes; fall back to a user-agent sniff for the browsers that
/// don't (Safari, Firefox). This only decides a cosmetic badge, so a rare
/// misclassification (an iPad reporting a desktop UA) is harmless.
function isMobileBrowser(): boolean {
  const uaData = (navigator as Navigator & { userAgentData?: { mobile?: boolean } }).userAgentData;
  if (uaData && typeof uaData.mobile === 'boolean') return uaData.mobile;
  return /Android|iPhone|iPad|iPod|Mobile|Opera Mini|IEMobile|BlackBerry/i.test(navigator.userAgent);
}
