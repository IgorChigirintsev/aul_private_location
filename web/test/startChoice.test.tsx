import { afterAll, describe, expect, it } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';
import { I18nextProvider } from 'react-i18next';
import { MemoryRouter } from 'react-router-dom';

import i18n from '../src/i18n';
import { StartChoice } from '../src/features/StartChoice';
import { parseInviteLink } from '../src/data/inviteLink';

describe('parseInviteLink', () => {
  it('extracts id + fragment from a full invite link', () => {
    const url = 'https://aul.example.com/i/abc123#Zm9vYmFyLWtleQ';
    expect(parseInviteLink(url)).toEqual({ inviteId: 'abc123', fragment: 'Zm9vYmFyLWtleQ' });
  });

  it('tolerates a bare path (no protocol/host)', () => {
    expect(parseInviteLink('/i/xyz#KEY')).toEqual({ inviteId: 'xyz', fragment: 'KEY' });
  });

  it('ignores a query string before the fragment', () => {
    expect(parseInviteLink('https://h/i/id9?ref=x#frag')).toEqual({ inviteId: 'id9', fragment: 'frag' });
  });

  it('trims surrounding whitespace', () => {
    expect(parseInviteLink('  https://h/i/id#frag  ')).toEqual({ inviteId: 'id', fragment: 'frag' });
  });

  it('rejects a link with no fragment', () => {
    expect(parseInviteLink('https://h/i/id')).toBeNull();
  });

  it('rejects a link with an empty fragment', () => {
    expect(parseInviteLink('https://h/i/id#')).toBeNull();
  });

  it('rejects a link with no /i/<id> segment', () => {
    expect(parseInviteLink('https://h/x/id#frag')).toBeNull();
  });

  it('rejects empty / garbage input', () => {
    expect(parseInviteLink('')).toBeNull();
    expect(parseInviteLink('not a link')).toBeNull();
  });
});

function render(): string {
  return renderToStaticMarkup(
    <I18nextProvider i18n={i18n}>
      <MemoryRouter>
        <StartChoice onCreate={() => {}} />
      </MemoryRouter>
    </I18nextProvider>,
  );
}

describe('StartChoice fork', () => {
  it('renders the two options in English (self-host dropped)', async () => {
    await i18n.changeLanguage('en');
    const html = render();
    expect(html).toContain('Create a circle');
    expect(html).toContain('Join an existing circle');
    // Self-host was removed — the fork offers only create + join now.
    expect(html).not.toContain('Run your own server');
  });

  it('renders the two options in Russian (self-host dropped)', async () => {
    await i18n.changeLanguage('ru');
    const html = render();
    expect(html).toContain('Создать круг');
    expect(html).toContain('Присоединиться к кругу');
    expect(html).not.toContain('Свой сервер');
  });
});

afterAll(async () => {
  await i18n.changeLanguage('en');
});
