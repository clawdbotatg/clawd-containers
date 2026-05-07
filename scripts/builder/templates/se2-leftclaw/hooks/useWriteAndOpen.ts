"use client";

import { useCallback } from "react";
import { useAccount } from "wagmi";

/**
 * Mobile WalletConnect deep-link helper.
 *
 * On mobile devices, a user who connected their wallet via WalletConnect goes
 * to the dApp page in their wallet's in-app browser, fires a transaction, and
 * then has to MANUALLY switch back to the wallet app to confirm the transaction.
 * The QA skill prescribes a "writeAndOpen" pattern: fire the write, and ~2s
 * later attempt to bring the wallet app forward so the confirmation prompt is
 * visible without manual app-switching.
 *
 * This hook returns:
 *   - `writeAndOpen`: wraps any async write fn, fires it, and on mobile
 *     schedules a deep-link attempt to the connected wallet's URI scheme
 *     after ~2 seconds. Errors from the underlying write are re-thrown
 *     unchanged so existing toast/notification logic keeps working.
 *   - `openWalletOnMobile`: side-effect-only helper if you want to call it
 *     directly after firing your own transaction (e.g. when you can't easily
 *     wrap the call site).
 *
 * The deep-link target is read from the active wagmi connector's `getProvider`
 * if the WalletConnect provider exposes a session peer with a redirect.native
 * URI; otherwise we fall back to a no-op (desktop wallets handle focus on
 * their own and don't need this).
 */
const isMobileUA = (): boolean => {
  if (typeof navigator === "undefined") return false;
  return /Mobi|Android|iPhone|iPad|iPod/i.test(navigator.userAgent);
};

const tryOpenWalletApp = async (connector: any): Promise<void> => {
  if (!connector || typeof window === "undefined") return;
  try {
    // Some connectors (Safe, etc.) expose openWalletApp directly.
    if (typeof connector.openWalletApp === "function") {
      connector.openWalletApp();
      return;
    }
    // WalletConnect v2 path: the provider holds the session metadata which
    // includes the wallet's `redirect.native` URI scheme. We open that.
    if (typeof connector.getProvider === "function") {
      const provider: any = await connector.getProvider();
      const session = provider?.session;
      const native = session?.peer?.metadata?.redirect?.native;
      if (typeof native === "string" && native.length > 0) {
        // setTimeout so we don't race the wallet's own bringup.
        window.location.href = native;
        return;
      }
      // Some versions stash the URI on `provider.signer.client.session.peer.metadata.redirect.native`
      const altNative = provider?.signer?.client?.session?.peer?.metadata?.redirect?.native;
      if (typeof altNative === "string" && altNative.length > 0) {
        window.location.href = altNative;
      }
    }
  } catch {
    // Best-effort. Never throw from a UX nudge.
  }
};

export const useWriteAndOpen = () => {
  const { connector } = useAccount();

  const openWalletOnMobile = useCallback(() => {
    if (!isMobileUA()) return;
    setTimeout(() => {
      void tryOpenWalletApp(connector);
    }, 2000);
  }, [connector]);

  const writeAndOpen = useCallback(
    async <T>(write: () => Promise<T>): Promise<T> => {
      // Schedule the deep-link nudge BEFORE awaiting — the wallet's prompt
      // typically appears within a couple hundred ms, and we want the
      // foreground bring-up to land while the user is still looking at the
      // dApp tab.
      openWalletOnMobile();
      return write();
    },
    [openWalletOnMobile],
  );

  return { writeAndOpen, openWalletOnMobile };
};
