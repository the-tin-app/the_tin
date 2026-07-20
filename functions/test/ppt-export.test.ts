import { describe, it, expect } from "vitest";
import Database from "better-sqlite3";
import {
  parseCsv, parseCardsExport, parseSealedExport, parseEbayExport, parsePopulationExport,
  ebayGradeToPsaColumn, applyExport,
} from "../src/pipeline/ppt-export";

// Sample CSVs use the documented export headers (api-reference, 2026-07-11).
const CARDS_CSV =
  "tcgPlayerId,name,setName,setId,cardNumber,rarity,language,printing,marketPrice,lowPrice,sellers,lastPriceUpdate\n" +
  "100,Pikachu,Base,base1,58,Common,EN,Holofoil,5.25,4.00,12,2026-07-11\n" +
  '200,"Charizard, Base",Base,base1,4,Rare,EN,Holofoil,350.00,300.00,8,2026-07-11\n' +
  "777,Orphan Card,Other,x,1,Common,EN,Normal,1.00,0.50,1,2026-07-11\n" + // no matching card
  "300,No Price,Base,base1,9,Common,EN,Normal,,,,2026-07-11\n";           // null market → skipped

// Real dumps use lowercase no-space grades ("psa10","cgc9"); median≠smartMarketPrice on purpose.
const EBAY_CSV =
  "tcgPlayerId,grade,salesCount,averagePrice,medianPrice,smartMarketPrice,smartMarketConfidence,marketPrice7Day,marketTrend,salesVelocityWeekly\n" +
  "200,psa10,40,1200,1150,1180.50,0.9,1175,up,3\n" +
  "200,psa9,30,600,590,585,0.9,580,flat,2\n" +
  "200,psa8,20,320,300,310,0.9,305,flat,2\n" +
  "200,psa9.5,4,800,780,790,0.7,785,flat,1\n" + // half grade → ignored for columns
  "200,cgc9,5,700,690,695,0.8,700,flat,1\n"; // non-PSA → ignored for columns

const SEALED_CSV =
  "tcgPlayerId,name,setName,setId,productType,language,marketPrice,lowPrice,sellers,lastPriceUpdate\n" +
  "9001,Base Booster Box,Base,base1,Booster Box,EN,7999.99,7500,3,2026-07-11\n";

const POP_CSV =
  "tcgPlayerId,grader,totalPopulation,gemRate,g1,g2,g3,g4,g5,g6,g7,g8,g9,g9_5,g10,auth,qualifiers,pristine,perfect,matchConfidence\n" +
  "200,PSA,5000,0.42,1,0,2,0,3,0,10,50,900,0,2100,0,0,0,0,0.99\n";

function makeDb(): Database.Database {
  const db = new Database(":memory:");
  db.exec(`
    CREATE TABLE card(id TEXT PRIMARY KEY, tcgplayer_id INTEGER);
    CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL,
      psa1 REAL, psa2 REAL, psa3 REAL, psa4 REAL, psa5 REAL, psa6 REAL,
      psa7 REAL, psa8 REAL, psa9 REAL, psa10 REAL, as_of TEXT NOT NULL);
    CREATE TABLE sealed_product(tcgplayer_id INTEGER PRIMARY KEY, name TEXT NOT NULL, set_id TEXT,
      product_type TEXT, market_usd REAL, low_usd REAL, as_of TEXT);
    CREATE TABLE population(card_id TEXT NOT NULL, grader TEXT NOT NULL, grade TEXT NOT NULL,
      count INTEGER, gem_rate REAL, total_population INTEGER, as_of TEXT NOT NULL,
      PRIMARY KEY(card_id, grader, grade));
    INSERT INTO card VALUES ('base1-58',100),('base1-4',200),('base1-9',300);
  `);
  return db;
}

describe("parseCsv (RFC-4180)", () => {
  it("handles quoted fields with embedded commas and CRLF", () => {
    const rows = parseCsv('a,b\r\n"x,y",z\r\n');
    expect(rows).toEqual([{ a: "x,y", b: "z" }]);
  });
  it('unescapes doubled quotes', () => {
    expect(parseCsv('a\n"he said ""hi"""')).toEqual([{ a: 'he said "hi"' }]);
  });
  it("ignores a trailing blank line", () => {
    expect(parseCsv("a\n1\n").length).toBe(1);
  });
});

describe("per-dataset parsers", () => {
  it("parses cards, keeping the embedded-comma name and nulling empty prices", () => {
    const rows = parseCardsExport(CARDS_CSV);
    expect(rows.map((r) => r.tcgPlayerId)).toEqual([100, 200, 777, 300]);
    expect(rows[1].name).toBe("Charizard, Base");
    expect(rows[3].marketPrice).toBeNull();
  });
  it("parses population grade columns into labels, dropping zero counts", () => {
    const [p] = parsePopulationExport(POP_CSV);
    expect(p.grader).toBe("PSA");
    expect(p.grades).toEqual({ "1": 1, "3": 2, "5": 3, "7": 10, "8": 50, "9": 900, "10": 2100 });
    expect(p.totalPopulation).toBe(5000);
  });
  it("parses sealed + ebay rows", () => {
    expect(parseSealedExport(SEALED_CSV)[0].productType).toBe("Booster Box");
    expect(parseEbayExport(EBAY_CSV).map((r) => r.grade)).toEqual(["psa10", "psa9", "psa8", "psa9.5", "cgc9"]);
  });
});

describe("ebayGradeToPsaColumn", () => {
  it("maps every integer PSA grade 1-10 (real lowercase form + tolerant of spaced)", () => {
    for (let g = 1; g <= 10; g++) expect(ebayGradeToPsaColumn(`psa${g}`)).toBe(`psa${g}`);
    expect(ebayGradeToPsaColumn("PSA 10")).toBe("psa10");
  });
  it("ignores half grades and other graders (cgc/bgs)", () => {
    expect(ebayGradeToPsaColumn("psa9.5")).toBeNull();
    expect(ebayGradeToPsaColumn("psa8_5")).toBeNull();
    expect(ebayGradeToPsaColumn("cgc6")).toBeNull();
    expect(ebayGradeToPsaColumn("bgs9.5")).toBeNull();
    expect(ebayGradeToPsaColumn("psa0")).toBeNull();
    expect(ebayGradeToPsaColumn("psa11")).toBeNull();
  });
});

describe("applyExport", () => {
  it("ingests raw + graded + sealed + population, skipping unmatched tcgPlayerIds", () => {
    const db = makeDb();
    const stats = applyExport(db, {
      cards: parseCardsExport(CARDS_CSV),
      ebay: parseEbayExport(EBAY_CSV),
      sealed: parseSealedExport(SEALED_CSV),
      population: parsePopulationExport(POP_CSV),
      asOf: "2026-07-11",
    });

    // cards: 100 + 200 matched & priced; 300 null-priced skipped; 777 unmatched.
    expect(stats.rawRows).toBe(2);
    expect(stats.unmatched).toBe(1);
    const char = db.prepare("SELECT * FROM price_latest WHERE card_id='base1-4'").get() as any;
    expect(char.raw_usd).toBe(350);
    expect(char.psa10).toBe(1150); // medianPrice, not smartMarketPrice (1180.5)
    expect(char.psa9).toBe(590);
    expect(char.psa8).toBe(300);   // psa8 has its own column now (was dropped pre-all-grades)
    expect(char.psa7).toBeNull();  // no psa7 row in the feed; half grades (psa9.5) don't land

    const box = db.prepare("SELECT * FROM sealed_product WHERE tcgplayer_id=9001").get() as any;
    expect(box.market_usd).toBe(7999.99);
    expect(box.product_type).toBe("Booster Box");

    const pop = db.prepare("SELECT grade, count FROM population WHERE card_id='base1-4' AND grade='10'").get() as any;
    expect(pop.count).toBe(2100);
    expect(stats.popRows).toBe(7); // grades 1,3,5,7,8,9,10
  });

  it("uses an explicit idByTcg override (build pipeline supplies every printing SKU)", () => {
    const db = makeDb(); // card table maps base1-58→100; override maps a DIFFERENT sku (555)
    const csv =
      "tcgPlayerId,name,setName,setId,cardNumber,rarity,language,printing,marketPrice,lowPrice,sellers,lastPriceUpdate\n" +
      "555,X,S,1,1,C,english,Normal,9.99,5,1,2026-07-11\n";
    const stats = applyExport(db, { cards: parseCardsExport(csv), asOf: "2026-07-11" },
      new Map<number, string>([[555, "base1-58"]]));
    expect(stats.rawRows).toBe(1); // matched via override, not the table's tcgplayer_id column
    expect((db.prepare("SELECT raw_usd FROM price_latest WHERE card_id='base1-58'").get() as any).raw_usd).toBe(9.99);
  });

  it("preserves an existing raw price when only graded data arrives (COALESCE upsert)", () => {
    const db = makeDb();
    db.prepare("INSERT INTO price_latest(card_id, raw_usd, as_of) VALUES ('base1-4', 999, '2026-01-01')").run();
    applyExport(db, { ebay: parseEbayExport(EBAY_CSV), asOf: "2026-07-11" });
    const row = db.prepare("SELECT raw_usd, psa10 FROM price_latest WHERE card_id='base1-4'").get() as any;
    expect(row.raw_usd).toBe(999);      // untouched by the graded-only upsert
    expect(row.psa10).toBe(1150);       // medianPrice
  });

  it("writes low_usd from the export lowPrice column", () => {
    const db = makeDb();
    applyExport(db, { cards: parseCardsExport(CARDS_CSV), asOf: "2026-07-11" });
    const KNOWN_CARD_ID = "base1-4";
    const EXPECTED_LOW = 300; // CARDS_CSV row 200 "Charizard, Base" lowPrice
    const low = db.prepare("SELECT low_usd FROM price_latest WHERE card_id = ?").pluck().get(KNOWN_CARD_ID);
    expect(low).toBe(EXPECTED_LOW);
  });
});

describe("applyExport with skuMeta (printing labels)", () => {
  // Card "base1-4" has two SKUs: 100 = 1st Edition (priority 0), 200 = Unlimited (priority 1).
  const idByTcg = new Map([[100, "base1-4"], [200, "base1-4"]]);
  const skuMeta = new Map([
    [100, { printing: "1st Edition", priority: 0 }],
    [200, { printing: "Unlimited", priority: 1 }],
  ]);

  it("raw_usd deterministically uses the highest-priority SKU regardless of row order", () => {
    const db = makeDb(); // the file's existing minimal-schema helper
    applyExport(db, {
      cards: [
        { tcgPlayerId: 200, name: "", setId: "", cardNumber: "", marketPrice: 50, lowPrice: null, sellers: null, lastPriceUpdate: "" },
        { tcgPlayerId: 100, name: "", setId: "", cardNumber: "", marketPrice: 400, lowPrice: null, sellers: null, lastPriceUpdate: "" },
      ],
      asOf: "2026-07-19",
    }, idByTcg, skuMeta);
    expect(db.prepare("SELECT raw_usd FROM price_latest WHERE card_id='base1-4'").get())
      .toEqual({ raw_usd: 400 }); // 1st Edition (priority 0), not last-written Unlimited
  });

  it("writes per-printing graded rows and keeps psaN on the highest-priority SKU", () => {
    const db = makeDb();
    const stats = applyExport(db, {
      ebay: [
        { tcgPlayerId: 200, grade: "psa10", smartMarketPrice: null, medianPrice: 900, averagePrice: null },
        { tcgPlayerId: 100, grade: "psa10", smartMarketPrice: null, medianPrice: 5000, averagePrice: null },
        { tcgPlayerId: 200, grade: "cgc9", smartMarketPrice: null, medianPrice: 300, averagePrice: null },
      ],
      asOf: "2026-07-19",
    }, idByTcg, skuMeta);
    expect(db.prepare("SELECT printing, grade, usd FROM graded_by_printing WHERE card_id='base1-4' ORDER BY printing, grade").all())
      .toEqual([
        { printing: "1st Edition", grade: "psa10", usd: 5000 },
        { printing: "Unlimited", grade: "cgc9", usd: 300 },
        { printing: "Unlimited", grade: "psa10", usd: 900 },
      ]);
    // psa10 column = 1st Edition's (priority 0); cgc9 has no psa column (existing behavior).
    expect(db.prepare("SELECT psa10 FROM price_latest WHERE card_id='base1-4'").get())
      .toEqual({ psa10: 5000 });
    expect(stats.gradedPrintingRows).toBe(3);
  });

  it("without skuMeta behaves exactly as before (no graded_by_printing writes)", () => {
    const db = makeDb();
    applyExport(db, {
      ebay: [{ tcgPlayerId: 100, grade: "psa10", smartMarketPrice: null, medianPrice: 5000, averagePrice: null }],
      asOf: "2026-07-19",
    }, idByTcg);
    expect(db.prepare("SELECT COUNT(*) AS n FROM graded_by_printing").get()).toEqual({ n: 0 });
  });

  it("a labeled SKU beats an unlabeled SKU (absent from skuMeta defaults to MAX_SAFE_INTEGER)", () => {
    const db = makeDb();
    const idByTcg2 = new Map([[100, "base1-4"], [300, "base1-4"]]);
    const skuMeta2 = new Map([[100, { printing: "1st Edition", priority: 5 }]]); // 300 has no entry
    applyExport(db, {
      cards: [
        { tcgPlayerId: 300, name: "", setId: "", cardNumber: "", marketPrice: 999, lowPrice: null, sellers: null, lastPriceUpdate: "" },
        { tcgPlayerId: 100, name: "", setId: "", cardNumber: "", marketPrice: 111, lowPrice: null, sellers: null, lastPriceUpdate: "" },
      ],
      ebay: [
        { tcgPlayerId: 300, grade: "psa10", smartMarketPrice: null, medianPrice: 900, averagePrice: null },
        { tcgPlayerId: 100, grade: "psa10", smartMarketPrice: null, medianPrice: 500, averagePrice: null },
      ],
      asOf: "2026-07-19",
    }, idByTcg2, skuMeta2);
    expect(db.prepare("SELECT raw_usd, psa10 FROM price_latest WHERE card_id='base1-4'").get())
      .toEqual({ raw_usd: 111, psa10: 500 }); // labeled SKU (priority 5) beats unlabeled (MAX_SAFE_INTEGER)
    // Only the labeled SKU's ebay row lands in graded_by_printing — the unlabeled SKU has no printing label.
    expect(db.prepare("SELECT printing, grade, usd FROM graded_by_printing WHERE card_id='base1-4'").all())
      .toEqual([{ printing: "1st Edition", grade: "psa10", usd: 500 }]);
  });

  it("an explicit priority tie is broken by input order (first row wins both raw_usd and the psa column)", () => {
    const db = makeDb();
    const idByTcg3 = new Map([[400, "base1-4"], [500, "base1-4"]]);
    const skuMeta3 = new Map([
      [400, { printing: "A", priority: 2 }],
      [500, { printing: "B", priority: 2 }], // same priority as 400
    ]);
    applyExport(db, {
      cards: [
        { tcgPlayerId: 400, name: "", setId: "", cardNumber: "", marketPrice: 111, lowPrice: null, sellers: null, lastPriceUpdate: "" },
        { tcgPlayerId: 500, name: "", setId: "", cardNumber: "", marketPrice: 222, lowPrice: null, sellers: null, lastPriceUpdate: "" },
      ],
      ebay: [
        { tcgPlayerId: 400, grade: "psa10", smartMarketPrice: null, medianPrice: 111, averagePrice: null },
        { tcgPlayerId: 500, grade: "psa10", smartMarketPrice: null, medianPrice: 222, averagePrice: null },
      ],
      asOf: "2026-07-19",
    }, idByTcg3, skuMeta3);
    expect(db.prepare("SELECT raw_usd, psa10 FROM price_latest WHERE card_id='base1-4'").get())
      .toEqual({ raw_usd: 111, psa10: 111 }); // 400 processed first, wins the tie
  });
});

describe("cards export sellers column", () => {
  it("parseCardsExport captures sellers (empty field → null)", () => {
    const rows = parseCardsExport(
      "tcgPlayerId,name,setId,cardNumber,marketPrice,lowPrice,sellers,lastPriceUpdate\n" +
      "246812,Metal Energy,swsh7,237/203,10.57,5.8,23,2026-07-18\n" +
      "246790,Treasure Energy,swsh7,165/203,0.05,,,2026-07-18");
    expect(rows[0].sellers).toBe(23);
    expect(rows[1].sellers).toBeNull();
  });

  it("applyExport writes sellers with the raw price (ALTER guard for pre-column fixtures)", () => {
    const db = new Database(":memory:");
    db.exec(`CREATE TABLE card(id TEXT PRIMARY KEY, tcgplayer_id INTEGER);
      CREATE TABLE price_latest(card_id TEXT PRIMARY KEY, raw_usd REAL, raw_eur REAL,
        psa1 REAL, psa2 REAL, psa3 REAL, psa4 REAL, psa5 REAL, psa6 REAL,
        psa7 REAL, psa8 REAL, psa9 REAL, psa10 REAL, as_of TEXT NOT NULL);
      CREATE TABLE sealed_product(tcgplayer_id INTEGER PRIMARY KEY, name TEXT NOT NULL, set_id TEXT,
        product_type TEXT, market_usd REAL, low_usd REAL, as_of TEXT);
      CREATE TABLE population(card_id TEXT NOT NULL, grader TEXT NOT NULL, grade TEXT NOT NULL,
        count INTEGER, gem_rate REAL, total_population INTEGER, as_of TEXT NOT NULL,
        PRIMARY KEY(card_id, grader, grade));`);
    db.prepare("INSERT INTO card VALUES ('swsh7-215', 246812)").run();
    applyExport(db, {
      cards: [{ tcgPlayerId: 246812, name: "Umbreon VMAX", setId: "swsh7", cardNumber: "215/203",
        marketPrice: 1350.5, lowPrice: null, sellers: 23, lastPriceUpdate: "" }],
      asOf: "2026-07-19",
    });
    const row = db.prepare("SELECT raw_usd, sellers FROM price_latest WHERE card_id='swsh7-215'").get() as any;
    expect(row).toEqual({ raw_usd: 1350.5, sellers: 23 });
  });

  it("parsePopulationExport captures auth/pristine/perfect specialty counts", () => {
    const rows = parsePopulationExport(
      "tcgPlayerId,grader,totalPopulation,gemRate,g1,g10,g9_5,auth,pristine,perfect\n" +
      "246812,BGS,120,10.5,2,50,7,3,4,1");
    expect(rows[0].grades).toEqual({ "1": 2, "10": 50, "9.5": 7, Auth: 3, Pristine: 4, Perfect: 1 });
  });
});
