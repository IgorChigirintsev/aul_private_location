/// The public Aul server this build points at out of the box.
///
/// Aul is self-hostable, so the field on the login screen stays EDITABLE — but
/// shipping it blank made a first run impossible: nothing in the UI says what
/// belongs there, and submitting an empty value surfaces only a bare
/// "network error", which reads like the app is broken rather than unconfigured.
const kDefaultServerUrl = 'https://136.66.203.133.nip.io';
