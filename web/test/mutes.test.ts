import { describe, expect, it } from 'vitest';

import { NO_MUTES, withCircleMuted, withMemberMuted } from '../src/data/mutes';
import type { MutesDTO } from '../src/data/types';

// PUT /v1/circles/{id}/mutes REPLACES the caller's whole mute set, so these
// helpers must always produce the COMPLETE desired state — dropping a field
// silently un-mutes someone.

describe('withCircleMuted', () => {
  it('flips the circle flag while preserving the member mutes', () => {
    const cur: MutesDTO = { circle_muted: false, muted_user_ids: ['ann', 'bob'] };
    expect(withCircleMuted(cur, true)).toEqual({
      circle_muted: true,
      muted_user_ids: ['ann', 'bob'],
    });
    expect(withCircleMuted({ circle_muted: true, muted_user_ids: [] }, false)).toEqual(NO_MUTES);
  });
});

describe('withMemberMuted', () => {
  it('adds and removes a member without touching the circle flag', () => {
    const cur: MutesDTO = { circle_muted: true, muted_user_ids: [] };
    const added = withMemberMuted(cur, 'ann', true);
    expect(added).toEqual({ circle_muted: true, muted_user_ids: ['ann'] });
    expect(withMemberMuted(added, 'ann', false)).toEqual({ circle_muted: true, muted_user_ids: [] });
  });

  it('never duplicates an id — the server rejects a sloppy list, and it is a REPLACE', () => {
    const once = withMemberMuted(NO_MUTES, 'ann', true);
    expect(withMemberMuted(once, 'ann', true).muted_user_ids).toEqual(['ann']);
  });

  it('is idempotent when unmuting someone who was never muted', () => {
    expect(withMemberMuted({ circle_muted: false, muted_user_ids: ['bob'] }, 'ann', false)).toEqual({
      circle_muted: false,
      muted_user_ids: ['bob'],
    });
  });

  it('keeps every OTHER member muted when one is unmuted', () => {
    const cur: MutesDTO = { circle_muted: false, muted_user_ids: ['ann', 'bob', 'cem'] };
    expect(withMemberMuted(cur, 'bob', false).muted_user_ids).toEqual(['ann', 'cem']);
  });

  it('does not mutate the input (the cache holds it until the server echoes back)', () => {
    const cur: MutesDTO = { circle_muted: false, muted_user_ids: ['ann'] };
    withMemberMuted(cur, 'bob', true);
    expect(cur.muted_user_ids).toEqual(['ann']);
  });
});
