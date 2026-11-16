import { createTheme } from "@mantine/core";

export const theme = createTheme({
  primaryColor: "gold",
  colors: {
    gold: [
      "#fbf5e5",
      "#f0e5c7",
      "#e0ce9d",
      "#ceb56d",
      "#b99a45",
      "#a3812d",
      "#80621d",
      "#6a5018",
      "#574114",
      "#453311",
    ],
    dark: [
      "#ece5d7",
      "#c5baaa",
      "#a99c8a",
      "#827464",
      "#5a4f43",
      "#40382f",
      "#302a24",
      "#26221e",
      "#201c19",
      "#181513",
    ],
  },
  primaryShade: { light: 6, dark: 3 },
  fontFamily:
    "system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
  headings: {
    fontFamily: "Georgia, 'Times New Roman', serif",
    sizes: {
      h1: { fontSize: "2rem" },
      h2: { fontSize: "1.4rem" },
      h3: { fontSize: "1.15rem" },
    },
  },
  defaultRadius: "sm",
  components: {
    Table: {
      defaultProps: {
        stripedColor: "var(--mantine-color-default-hover)",
        highlightOnHoverColor: "var(--mantine-color-default-border)",
      },
    },
    Select: {
      defaultProps: { clearButtonProps: { "aria-label": "Clear selection" } },
    },
    MultiSelect: {
      defaultProps: { clearButtonProps: { "aria-label": "Clear selections" } },
    },
  },
});
