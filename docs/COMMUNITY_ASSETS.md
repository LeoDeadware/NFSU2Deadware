# Community assets in NFSU2 for Mac

Owner decisions (Deadware/CLAUDE.md, 2026-11-07): community HD textures and car models may be used,
including packs whose authors forbid redistribution, always with the authors credited here and in the
DMG notices; on a complaint the asset is removed within 24 hours (DMCA).

How they get in: `tools/hd/community.py` (unpack a TexMod .tpf with `tools/hd/tpf.py`, map its PC
textures onto our Xbox texture dumps by content with `tools/hd/tpfmatch.swift`, merge over our 4x pack:
`work/hd/pack-merged`, build with `NFSU2_HD_PACK=work/hd/pack-merged`). Downloads stay outside the repo
(`Deadware/Port ISOs/NFSU2-mods/`, unpacked into `.cache/community/<tag>`); nothing of them is committed.

| Tag | Pack | Author | Source | Licence / permissions | Used | Textures replaced |
|-----|------|--------|--------|-----------------------|------|-------------------|
| remaster23 | Remastered Underground 2 (REMASTER.tpf) | instanity | [Nexus 23](https://www.nexusmods.com/needforspeedunderground2/mods/23) | per Nexus page; used under the owner decision above | yes | 45 |
| redux13 | Need for Speed Underground 2 Redux HD Textures | Awesome Mods (epicawesomemods) | [Nexus 13](https://www.nexusmods.com/needforspeedunderground2/mods/13) | per Nexus page; used under the owner decision above | yes | 6 |
| nextgen31 | Need for Speed Underground 2 Next-Gen Textures | Awesome Mods (epicawesomemods) | [Nexus 31](https://www.nexusmods.com/needforspeedunderground2/mods/31) | per Nexus page; used under the owner decision above | yes | 7 |
| revit90 | Need for Speed Underground 2 - Project Revitalized (its 4 .tpf packs only) | QTmodz | [Nexus 90](https://www.nexusmods.com/needforspeedunderground2/mods/90) | per Nexus page; used under the owner decision above | yes | 23 |
| sky61 | 8K Realistic Night Skyboxes for NFSU2 (TRACKS/LOC4DYNTEX.BIN, tools/hd/tpk.py) | Awesome Mods (epicawesomemods) | [Nexus 61](https://www.nexusmods.com/needforspeedunderground2/mods/61) | per Nexus page; used under the owner decision above | yes | 1 |
| smoke24 | megus_vae's Smoke Retexture | megus_vae (megusvae) | [Nexus 24](https://www.nexusmods.com/needforspeedunderground2/mods/24) | per Nexus page; used under the owner decision above | matched, not used | 0 (our 4x upscale of the same texture wins over its 2x) |

Settings per pack (thresholds, rejected matches): `tools/hd/community.tsv`, chosen on contact sheets of
every match (Xbox texture beside the PC one). Merge order (later wins): revit90, remaster23, redux13,
nextgen31, sky61, smoke24 -> 617 textures, 74 unique from the community (82 wins, some hashes won by a later pack).
Limits: only Xbox textures seen in our census (menus + one race) can be matched; PC-only art (ReShade
shaders, LUTs, DLL patches of Revitalized) does not port; UI textures are skipped (PC menus differ).

Not used:
- Bayview's Best (car pack, Nexus 39 / nfsmods 5196): PC car geometry (.BIN solid lists, PC vertex
  formats) does not fit the Xbox car files; would need a converter. Re-checked when the file arrives.
