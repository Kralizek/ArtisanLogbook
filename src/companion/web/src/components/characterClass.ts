/** Readable class label from the client's class file token (e.g. DEATHKNIGHT). */
export function className(classFile?: string | null) {
  if (!classFile) return "";
  const known: Record<string, string> = {
    DEATHKNIGHT: "Death Knight",
    DEMONHUNTER: "Demon Hunter",
  };
  return (
    known[classFile] ?? classFile.charAt(0) + classFile.slice(1).toLowerCase()
  );
}

// The game's conventional class colors, as the addon uses for character names.
export const classColors: Record<string, string> = {
  DEATHKNIGHT: "#C41E3A",
  DEMONHUNTER: "#A330C9",
  DRUID: "#FF7C0A",
  EVOKER: "#33937F",
  HUNTER: "#AAD372",
  MAGE: "#3FC7EB",
  MONK: "#00FF98",
  PALADIN: "#F48CBA",
  PRIEST: "#FFFFFF",
  ROGUE: "#FFF468",
  SHAMAN: "#0070DD",
  WARLOCK: "#8788EE",
  WARRIOR: "#C69B6D",
};
