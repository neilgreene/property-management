import subprocess, hashlib, json
from decimal import Decimal

rows = subprocess.run(
    ["psql","-d","sdi","-At","-F","|","-c",
     "select property_id,listing_ref,city,state,zip,property_type,beds,baths,sqft,"
     "year_built,list_price,gross_rent_annual,opex_annual,hoa_annual "
     "from core.property order by listing_ref"],
    capture_output=True, text=True, check=True).stdout.strip().split("\n")

AREAS = [
    # city, state, med hh income, med home price, med rent, rent growth bps, vacancy bps, population
    ("Cleveland","OH",    40012, 115000, 1150, 320,  940, 362656),
    ("Columbus","OH",     62994, 245000, 1395, 280,  620, 913175),
    ("Toledo","OH",       45231, 120500,  950, 250,  880, 265304),
    ("Indianapolis","IN", 58146, 235000, 1320, 300,  730, 887642),
    ("Memphis","TN",      47000, 165000, 1215, 210, 1020, 621056),
    ("Tampa","FL",        65389, 395000, 1975, 180,  680, 403364),
    ("Kansas City","MO",  62371, 255000, 1285, 340,  700, 510704),
    ("Huntsville","AL",   65226, 305000, 1325, 360,  640, 225564),
    ("Birmingham","AL",   41031, 130000, 1090, 230, 1110, 196910),
]
AREA_BY = {(c,s): a for a in AREAS for c,s in [(a[0],a[1])]}

# Effective property-tax rate by state, in basis points of value. Rough
# state-level averages -- demo figures, not an assessor's numbers.
TAX_BPS  = {"OH":152,"TN":66,"IN":84,"FL":98,"MO":97,"AL":41}
# Insurance as bps of value. Florida carries the well-known premium.
INS_BPS  = {"OH":52,"TN":58,"IN":50,"FL":124,"MO":61,"AL":72}

HEAT = ["Forced air, natural gas","Forced air, natural gas","Hot water baseboard",
        "Heat pump","Forced air, electric"]
COOL = ["Central air","Central air","Central air","Window units","Heat pump"]
PARK = ["Attached garage","Detached garage","Driveway","Off-street pad","On-street"]

FEATURES = ["Hardwood floors","Updated kitchen","Fenced yard","Basement","Covered porch",
            "In-unit laundry","Stainless appliances","New water heater","Vinyl replacement windows",
            "Separately metered","Off-street parking","Storage shed"]

def seeded(pid, salt, n):
    h = hashlib.sha256((pid+salt).encode()).digest()
    return int.from_bytes(h[:8],"big") % n

def q(v):
    return "NULL" if v is None else "'" + str(v).replace("'","''") + "'"

props, details, media = [], [], []

for line in rows:
    (pid, ref, city, state, zipc, ptype, beds, baths, sqft, yb,
     price, gross, opex, hoa) = line.split("|")

    # Skip anything without the facts this generator derives from. The
    # tracked-but-unverified Irvine listing and any workbook import that
    # has not been filled in have null sizes on purpose, and inventing
    # figures for them is exactly what the rest of the system exists to
    # prevent. They get their detail from the import, not from here.
    if not (beds and sqft and yb and price and gross):
        continue
    beds, sqft, yb = int(beds), int(sqft), int(yb)
    baths = float(baths)
    price, gross, opex, hoa = (float(price), float(gross), float(opex), float(hoa))
    area = AREA_BY[(city,state)]

    # --- what it earns -------------------------------------------------
    rent_m = round(gross/12)
    basis = ["in_place","in_place","market_estimate","pro_forma"][seeded(pid,"basis",4)]

    # --- what it costs to hold -----------------------------------------
    # Raw figures from rules, then scaled so the components sum EXACTLY to
    # the opex_annual already published on the listing. An investor who
    # adds up the breakdown gets the headline number back.
    owner_utils = ptype in ("Duplex","Triplex") or (ptype == "Condo" and seeded(pid,"util",2) == 0)
    tax_raw = price * TAX_BPS[state] / 10000
    ins_raw = price * INS_BPS[state] / 10000
    util_m_raw = round(0.055*sqft + 45 + seeded(pid,"um",40))
    maint_raw = max(sqft * 0.55, 900)

    parts = {"tax":tax_raw, "ins":ins_raw, "maint":maint_raw}
    if owner_utils:
        parts["util"] = util_m_raw*12
    scale = opex / sum(parts.values())
    tax   = round(parts["tax"]*scale, 2)
    ins   = round(parts["ins"]*scale, 2)
    maint = round(parts["maint"]*scale, 2)
    if owner_utils:
        util_m = round(parts["util"]*scale/12, 2)
        # absorb the rounding drift into maintenance so the sum is exact
        maint = round(opex - tax - ins - util_m*12, 2)
        paid_by = "owner"
    else:
        util_m = float(util_m_raw)          # tenant pays; informational only
        maint = round(opex - tax - ins, 2)
        paid_by = "tenant" if ptype in ("Single Family","Townhouse") else "split"

    mgmt_bps = [700,800,800,900,1000][seeded(pid,"mgmt",5)]
    vac_bps  = int(round(area[6]/100.0))*100

    # --- the building ---------------------------------------------------
    lot = None if ptype == "Condo" else int(sqft * (1.6 + seeded(pid,"lot",180)/100.0))
    stories = 1 if ptype == "Single Family" and sqft < 1600 else (2 if seeded(pid,"st",3) else 3)
    garage = 0 if ptype == "Condo" else seeded(pid,"gar",3)
    roof = min(2024, yb + 15 + seeded(pid,"roof",30))
    reno = None if seeded(pid,"reno",3) == 0 else min(2024, max(yb+10, 2005 + seeded(pid,"reno2",19)))
    feats = sorted({FEATURES[seeded(pid,"f%d"%i,len(FEATURES))] for i in range(4)})

    adj = ["Turnkey","Well-kept","Cash-flowing","Value-add","Recently updated","Stabilised"][seeded(pid,"adj",6)]
    headline = f"{adj} {beds}-bed {ptype.lower()} in {city}"
    desc = (f"{ptype} of {sqft:,} sq ft built in {yb}, {beds} bed / {baths:g} bath. "
            f"Currently underwritten at ${rent_m:,}/mo "
            f"({'in place' if basis=='in_place' else basis.replace('_',' ')}) against a "
            f"{city} median rent of ${area[4]:,}. "
            f"Operating expenses of ${opex:,.0f} a year cover taxes, insurance, "
            f"{'owner-paid utilities, ' if owner_utils else ''}and maintenance. "
            f"Address released on execution of the platform fee agreement.")

    details.append(
      f"({q(pid)},{q(headline)},{q(desc)},{rent_m},{q(basis)},"
      f"{tax},{ins},{util_m},{q(paid_by)},{maint},{mgmt_bps},{vac_bps},"
      f"{lot if lot is not None else 'NULL'},{stories},{garage},"
      f"{q(HEAT[seeded(pid,'h',5)])},{q(COOL[seeded(pid,'c',5)])},{roof},"
      f"{reno if reno is not None else 'NULL'},{q(PARK[seeded(pid,'p',5)])},"
      f"{q(json.dumps(feats))}::jsonb)")

    # --- photographs -----------------------------------------------------
    # Image 1 is the front elevation: it identifies the property, so it is
    # flagged and released with the address. The hero shown on the card is
    # a public interior, so every viewer sees a card with a picture.
    shots = [
        ("hero",     "Property",                        False, True),
        ("front",    "Front elevation from the street", True,  False),
        ("living",   "Living area",                     False, False),
        ("kitchen",  "Kitchen",                         False, False),
        ("bed",      "Primary bedroom",                 False, False),
    ]
    if ptype in ("Duplex","Triplex"):
        shots[3] = ("unit", "Second unit, living area", False, False)
    for i,(kind,cap,reveals,primary) in enumerate(shots):
        media.append(f"({q(pid)},{q('/media/'+pid+'/'+kind+'.svg')},{q(cap)},{i},"
                     f"{str(primary).lower()},{str(reveals).lower()})")

out = []
out.append("""-- =====================================================================
-- 20_demo_detail_seed.sql  |  demo data for the drill-down
-- =====================================================================
-- DEMO DATA. The market figures are plausible, round, and made up: they
-- are the right order of magnitude for each city but they are not an ACS
-- extract and nothing should be underwritten on them.
--
-- Generated by docs/gen_detail.py from the listings already in
-- core.property, so the numbers agree with the listings rather than
-- floating free of them. In particular the expense breakdown SUMS TO the
-- opex_annual already published on each listing -- an investor who adds
-- up taxes, insurance, utilities and maintenance gets the headline figure
-- back. That property is what makes the detail page believable, and it is
-- why this file is generated rather than typed.

BEGIN;

INSERT INTO core.market_area
 (area_id, city, state, median_household_income, median_home_price,
  median_rent_monthly, rent_growth_1y_bps, vacancy_rate_bps, population) VALUES""")
out.append(",\n".join(
    f" ({q(c+', '+s)},{q(c)},{q(s)},{inc},{hp},{rent},{g},{v},{pop})"
    for c,s,inc,hp,rent,g,v,pop in AREAS) + "\nON CONFLICT (area_id) DO NOTHING;\n")

out.append("""INSERT INTO core.property_detail
 (property_id, headline, description, market_rent_monthly, rent_basis,
  property_tax_annual, insurance_annual, utilities_monthly, utilities_paid_by,
  maintenance_annual, management_fee_bps, vacancy_allowance_bps,
  lot_sqft, stories, garage_spaces, heating, cooling, roof_year,
  last_renovated, parking, features) VALUES""")
out.append(",\n".join(" "+d for d in details) + "\nON CONFLICT (property_id) DO NOTHING;\n")

out.append("""INSERT INTO core.property_media
 (property_id, url, caption, position, is_primary, reveals_location) VALUES""")
out.append(",\n".join(" "+m for m in media) + ";\n")

out.append("COMMIT;")
open("sql/20_demo_detail_seed.sql","w").write("\n".join(out)+"\n")
print("wrote", len(details), "details,", len(media), "media rows")
