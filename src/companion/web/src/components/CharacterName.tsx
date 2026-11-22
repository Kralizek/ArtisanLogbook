import { VisuallyHidden } from "@mantine/core";
import { classColors, className } from "./characterClass";

/**
 * A character name with its class color as a swatch. The name keeps body text
 * color so it stays readable on parchment, where several class colors are not.
 */
export function CharacterName({
  name,
  classFile,
}: {
  name?: string | null;
  classFile?: string | null;
}) {
  const color = classFile ? classColors[classFile] : undefined;
  return (
    <span className="character-name">
      {color && (
        <span
          className="class-swatch"
          style={{ background: color }}
          title={className(classFile)}
          aria-hidden
        />
      )}
      {name ?? "Unknown character"}
      {classFile && <VisuallyHidden>, {className(classFile)}</VisuallyHidden>}
    </span>
  );
}
