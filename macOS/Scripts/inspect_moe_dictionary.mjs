import { FileBlob, SpreadsheetFile } from "@oai/artifact-tool";

const inputPath = new URL(
  "../build/moe_dictionary/dict_revised_2015_20260625.xlsx",
  import.meta.url,
).pathname;
const input = await FileBlob.load(inputPath);
const workbook = await SpreadsheetFile.importXlsx(input);
const overview = await workbook.inspect({
  kind: "workbook,sheet,table",
  maxChars: 6000,
  tableMaxRows: 8,
  tableMaxCols: 12,
  tableMaxCellChars: 120,
});
console.log(overview.ndjson);

const sheet = workbook.worksheets.getItemAt(0);
const header = await workbook.inspect({
  kind: "region",
  sheetId: sheet.name,
  range: "A1:L8",
  maxChars: 6000,
  tableMaxRows: 8,
  tableMaxCols: 12,
  tableMaxCellChars: 240,
});
console.log(header.ndjson);
