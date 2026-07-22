import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import { RealtimeClient } from '../src/data/realtime';
import { useConnection } from '../src/store/connection';

/// A dropped realtime connection must be CLIENT-inferred: an offline or
/// unreachable server cannot announce its own offline-ness. These tests pin the
/// wiring that turns the socket's own open/close into the `online` flag the
/// dashboard reads to show (or hide) its "live updates paused" banner — so a lost
/// link never leaves the map looking live.

/// A stand-in for the browser WebSocket the client constructs. It records every
/// instance and does nothing on its own, so the test drives open/close by hand
/// (a real socket fires these asynchronously).
class FakeWebSocket {
  static instances: FakeWebSocket[] = [];
  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: string }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  closed = false;
  constructor(public url: string) {
    FakeWebSocket.instances.push(this);
  }
  close() {
    this.closed = true;
  }
  static last(): FakeWebSocket {
    return FakeWebSocket.instances[FakeWebSocket.instances.length - 1];
  }
}

function connectWiredClient(): RealtimeClient {
  const client = new RealtimeClient(new Map(), {
    onStatus: (connected) => useConnection.getState().setOnline(connected),
  });
  client.connect();
  return client;
}

beforeEach(() => {
  FakeWebSocket.instances = [];
  useConnection.getState().setOnline(true);
  vi.stubGlobal('WebSocket', FakeWebSocket);
  vi.stubGlobal('location', { protocol: 'https:', host: 'server.test' });
  vi.useFakeTimers();
});

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllGlobals();
});

describe('realtime connection → connection store', () => {
  it('starts optimistically online (no banner on first paint)', () => {
    expect(useConnection.getState().online).toBe(true);
  });

  it('flips the flag OFFLINE when the socket drops, and back ONLINE on reconnect', () => {
    const client = connectWiredClient();

    // Socket opens: healthy, banner stays hidden.
    FakeWebSocket.last().onopen?.();
    expect(useConnection.getState().online).toBe(true);

    // Server goes away / network drops: onclose (not an intentional close) must
    // flip the visible flag so the dashboard can show "live updates paused".
    FakeWebSocket.last().onclose?.();
    expect(useConnection.getState().online).toBe(false);

    // The client backs off (1s → 2s after one drop) and reopens; that new socket
    // connecting clears the flag.
    const before = FakeWebSocket.instances.length;
    vi.advanceTimersByTime(2000);
    expect(FakeWebSocket.instances.length).toBe(before + 1); // reconnect attempt
    FakeWebSocket.last().onopen?.();
    expect(useConnection.getState().online).toBe(true);

    client.close();
  });

  it('stamps lastOnlineAt on the drop, keeps it across failed reconnects, clears on reconnect', () => {
    // Online: nothing to be stale about.
    expect(useConnection.getState().lastOnlineAt).toBeNull();

    // The true→false drop freezes the moment, so the banner can say "last
    // connected N ago" — the honest staleness a viewer needs.
    useConnection.getState().setOnline(false);
    const stamped = useConnection.getState().lastOnlineAt;
    expect(stamped).not.toBeNull();

    // A later failed reconnect (another 'false') must NOT move it — the age has
    // to count from the FIRST moment the link went down, not from each retry.
    vi.advanceTimersByTime(60_000);
    useConnection.getState().setOnline(false);
    expect(useConnection.getState().lastOnlineAt).toBe(stamped);

    // Reconnecting clears it: there is nothing stale to warn about anymore.
    useConnection.getState().setOnline(true);
    expect(useConnection.getState().lastOnlineAt).toBeNull();
  });

  it('does NOT report offline on an intentional close (circle switch / unmount)', () => {
    const client = connectWiredClient();
    FakeWebSocket.last().onopen?.();
    expect(useConnection.getState().online).toBe(true);

    // Tearing the subscription down closes the socket; the browser then fires
    // onclose asynchronously. That teardown is not a lost connection, so it must
    // not flip the banner on — otherwise switching circles would flash it.
    const ws = FakeWebSocket.last();
    client.close();
    ws.onclose?.();
    expect(useConnection.getState().online).toBe(true);

    // And no reconnect is scheduled after an intentional close.
    const count = FakeWebSocket.instances.length;
    vi.advanceTimersByTime(30_000);
    expect(FakeWebSocket.instances.length).toBe(count);
  });
});
