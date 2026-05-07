import type { Metadata } from "next";

// Resolve a real production URL for OG image baking. Next.js 15 normalizes
// relative image paths against `metadataBase`, and if metadataBase is undefined
// it falls back to `http://localhost:3000` — which would silently bake a
// localhost URL into every static-export HTML file and break social card
// unfurls everywhere.
//
// Resolution order:
//   1. `NEXT_PUBLIC_PRODUCTION_URL` — explicit override at build time
//   2. `VERCEL_PROJECT_PRODUCTION_URL` — automatic Vercel preview/production URL
//   3. `https://leftclaw.services` — stable fallback for IPFS-hosted builds
const productionUrl = process.env.NEXT_PUBLIC_PRODUCTION_URL
  ? process.env.NEXT_PUBLIC_PRODUCTION_URL
  : process.env.VERCEL_PROJECT_PRODUCTION_URL
    ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}`
    : "https://leftclaw.services";

const titleTemplate = "%s | __TITLE_TEMPLATE__";

export const getMetadata = ({
  title,
  description,
  imageRelativePath = "/og.png",
}: {
  title: string;
  description: string;
  imageRelativePath?: string;
}): Metadata => {
  const imageUrl = `${productionUrl}${imageRelativePath}`;

  return {
    metadataBase: new URL(productionUrl),
    title: {
      default: title,
      template: titleTemplate,
    },
    description: description,
    openGraph: {
      title: {
        default: title,
        template: titleTemplate,
      },
      description: description,
      images: [
        {
          url: imageUrl,
        },
      ],
    },
    twitter: {
      title: {
        default: title,
        template: titleTemplate,
      },
      description: description,
      images: [imageUrl],
    },
    icons: {
      icon: [
        {
          url: "/icon.svg",
          type: "image/svg+xml",
        },
      ],
    },
  };
};
