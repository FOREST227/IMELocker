// Rasterize our editable SVG source without a Quick Look white background.
const sharp = require('sharp');
const [source, destination] = process.argv.slice(2);
if (!source || !destination) {
  throw new Error('Usage: node render_icon.cjs source.svg destination.png');
}
sharp(source).ensureAlpha().png().toFile(destination).catch(error => {
  console.error(error);
  process.exitCode = 1;
});
