import { usePositions } from '../store/positions';
import { pingToPosition } from './pingDecode';
import type { RealtimeEvent, RemotePing } from './types';

export interface RealtimeHandlers {
  onSos?: (circleId: string, payload: unknown) => void;
  onSosResolved?: (circleId: string, sosId: string) => void;
  onPlaceUpdated?: (circleId: string) => void;
  onPrecision?: (circleId: string) => void;
  onMemberChanged?: (circleId: string) => void;
  onStatus?: (connected: boolean) => void;
}

/// WebSocket client for /v1/realtime. Receives encrypted ping/SOS events, and on
/// a ping decrypts it CLIENT-SIDE with the circle key K_c and updates the
/// positions store — so watchers see members move live. Reconnects with backoff;
/// the dashboard also polls latest pings every 30 s as a fallback.
export class RealtimeClient {
  private ws: WebSocket | null = null;
  private closed = false;
  private backoff = 1000;

  constructor(
    private keysByCircle: Map<string, Uint8Array[]>,
    private handlers: RealtimeHandlers = {},
  ) {}

  connect(): void {
    this.closed = false;
    this.open();
  }

  private open(): void {
    const proto = location.protocol === 'https:' ? 'wss' : 'ws';
    const ws = new WebSocket(`${proto}://${location.host}/v1/realtime`);
    this.ws = ws;
    ws.onopen = () => {
      this.backoff = 1000;
      this.handlers.onStatus?.(true);
    };
    ws.onmessage = (ev) => this.handle(String(ev.data));
    ws.onclose = () => {
      // An intentional teardown (close(): circle switch / unmount) is not a lost
      // connection — don't report it as disconnected, or the dashboard would
      // flash "live updates paused" every time you switch circles.
      if (this.closed) return;
      this.handlers.onStatus?.(false);
      this.backoff = Math.min(this.backoff * 2, 30_000);
      setTimeout(() => this.open(), this.backoff);
    };
    ws.onerror = () => ws.close();
  }

  private handle(data: string): void {
    let evt: RealtimeEvent;
    try {
      evt = JSON.parse(data) as RealtimeEvent;
    } catch {
      return;
    }
    switch (evt.type) {
      case 'ping': {
        if (!evt.circle_id) return;
        const keyring = this.keysByCircle.get(evt.circle_id);
        if (!keyring || keyring.length === 0) return;
        const pos = pingToPosition(evt.payload as RemotePing, keyring);
        if (pos) usePositions.getState().upsert(pos);
        break;
      }
      case 'sos':
        if (evt.circle_id) this.handlers.onSos?.(evt.circle_id, evt.payload);
        break;
      case 'sos_resolved': {
        const id = (evt.payload as { id?: string } | undefined)?.id;
        if (evt.circle_id && id) this.handlers.onSosResolved?.(evt.circle_id, id);
        break;
      }
      case 'place_updated':
        if (evt.circle_id) this.handlers.onPlaceUpdated?.(evt.circle_id);
        break;
      case 'precision_mode':
        if (evt.circle_id) this.handlers.onPrecision?.(evt.circle_id);
        break;
      case 'member_changed':
        if (evt.circle_id) this.handlers.onMemberChanged?.(evt.circle_id);
        break;
      default:
        break;
    }
  }

  updateKeys(keys: Map<string, Uint8Array[]>): void {
    this.keysByCircle = keys;
  }

  close(): void {
    this.closed = true;
    this.ws?.close();
  }
}
