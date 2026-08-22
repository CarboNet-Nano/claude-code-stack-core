// PPTX renderer for the handbook deck (ADR-081 D5). Consumes the same
// slides.json the HTML renderer uses, so the two outputs cannot disagree.
import { readFileSync } from 'node:fs';
import PptxGenJS from 'pptxgenjs';

export async function buildPptx(slidesJsonPath, outPath) {
  const slides = JSON.parse(readFileSync(slidesJsonPath, 'utf8'));
  const pptx = new PptxGenJS();
  pptx.layout = 'LAYOUT_16x9';
  pptx.defineSlideMaster({
    title: 'STACK',
    background: { color: 'FFFFFF' },
    objects: [
      { rect: { x: 0, y: 5.2, w: '100%', h: 0.08, fill: { color: '4F46E5' } } },
    ],
  });
  for (const s of slides) {
    const slide = pptx.addSlide({ masterName: 'STACK' });
    slide.addText(s.title, { x: 0.6, y: 0.5, w: 8.8, h: 1.0, fontSize: 32, bold: true, color: '1A1A2E', fontFace: 'Helvetica' });
    slide.addText(s.takeaway, { x: 0.6, y: 1.55, w: 8.8, h: 0.9, fontSize: 18, bold: true, color: '4F46E5', fontFace: 'Helvetica' });
    if (s.bullets && s.bullets.length) {
      slide.addText(s.bullets.map(b => ({ text: b, options: { bullet: true, fontSize: 15, color: '333344', breakLine: true } })), { x: 0.8, y: 2.6, w: 8.4, h: 2.4, fontFace: 'Helvetica', valign: 'top' });
    }
    if (s.notes) slide.addNotes(s.notes);
  }
  await pptx.writeFile({ fileName: outPath });
}
