import {
  createPublicClient,
  createWalletClient,
  defineChain,
  fallback,
  http,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { chainConfig, keeperConfig } from "./config.js";

function chain() {
  const id = chainConfig.chainId();
  return defineChain({
    id,
    name: `tetragold-${id}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [chainConfig.rpcUrl()] } },
  });
}

function transport() {
  const primary = http(chainConfig.rpcUrl(), { timeout: 10_000, retryCount: 2 });
  const backup = chainConfig.rpcUrlFallback();
  return backup ? fallback([primary, http(backup, { timeout: 10_000, retryCount: 2 })]) : primary;
}

export function publicClient(): PublicClient {
  return createPublicClient({ chain: chain(), transport: transport() });
}

export function keeperWallet(): { wallet: WalletClient; account: ReturnType<typeof privateKeyToAccount> } {
  const pk = keeperConfig.privateKey();
  const account = privateKeyToAccount(pk.startsWith("0x") ? (pk as `0x${string}`) : (`0x${pk}` as `0x${string}`));
  const wallet = createWalletClient({ account, chain: chain(), transport: transport() });
  return { wallet, account };
}
