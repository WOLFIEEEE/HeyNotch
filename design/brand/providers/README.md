# Official provider artwork

These marks identify the optional processing providers supported by HeyNotch. They are not HeyNotch branding and do not indicate a partnership or endorsement. Provider names remain visible beside each mark. Artwork is bundled locally; displaying it does not contact the providers.

## Sources

- **Claude:** the unmodified **Claude Spark – Clay** SVG from [Anthropic’s official press kit](https://www.anthropic.com/press-kit), linked from the [Anthropic newsroom](https://www.anthropic.com/news). See the [Anthropic trademark guidelines](https://www.anthropic.com/legal/trademark-guidelines).
- **OpenAI:** the complete, unmodified Blossom SVG embedded in the public [OpenAI Developers](https://developers.openai.com/) header for its ChatGPT documentation variant. Its original `currentColor` fill supports the source website’s black/white appearance. No download agreement was accepted. See [OpenAI’s design guidelines](https://openai.com/brand/).
- **OpenRouter:** the original **Ink** (light background) and **Cloud** (dark background) glyph SVGs linked from [OpenRouter’s official brand assets](https://openrouter.ai/brand/). These are the small-format glyphs recommended by the source page.

[provenance.json](provenance.json) records exact URLs, the Claude archive member, OpenAI source-page checksum and selector, and SHA-256 checksums of the original SVG bytes. The native asset catalog keeps these files unchanged. Its OpenAI template setting supplies only black or white to the original monochrome shape; OpenRouter uses the provider’s separate Ink and Cloud originals. No logo was generated, traced, redrawn, stretched, or given an accent tint.

## Integration

Native images are `ProviderClaude`, `ProviderOpenAI`, and `ProviderOpenRouter` in `HeyNotch/Assets.xcassets`. The standard provider picker remains keyboard accessible. Each icon fits an 18 × 18 point box without changing its aspect ratio; the adjacent provider name supplies its accessible label.

The marketing site uses the same three light-background SVGs in `dist/assets/providers/`, displayed in bounded square boxes with `object-fit: contain`. Empty image alternatives avoid repeating the adjacent readable provider name. The site is light themed; its logo files are not inverted by the system theme.

## Ownership and usage terms

Claude and Anthropic marks belong to Anthropic, PBC; OpenAI marks belong to OpenAI; OpenRouter marks belong to OpenRouter, Inc. These assets retain their owners’ trademark and artwork terms and are not being represented as newly GPL-licensed artwork.

The sources establish provenance, not a claim of provider approval. Anthropic’s published trademark guidelines explicitly describe prior approval of materials. No separate approval has been obtained or asserted by this implementation. The marks are presented only as supported-provider identifiers; any release assessment of the provider terms remains separate from this technical change. OpenAI’s guidance requires exact artwork, relevant service context, clear ownership, and no implied endorsement. OpenRouter’s brand page instructs users not to stretch, recolor, or remix its marks.
