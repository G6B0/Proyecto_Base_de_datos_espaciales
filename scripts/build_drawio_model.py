"""Genera docs/modelo_logico.drawio: el modelo logico en draw.io (diagrams.net).

Dos paginas:
  1. Datos cargados: sismos, DPA, censo, magnitudes y procedencia.
  2. Tablas de analisis: emparejamiento, replicas e intensidad.

El archivo es editable en https://app.diagrams.net (Archivo > Abrir).
Uso:  python scripts/build_drawio_model.py
"""

from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "modelo_logico.drawio"

ROW_H = 26
HEAD_H = 32
KEY_W = 54

COLORS = {
    "proc": ("#f5f5f5", "#666666"),
    "mag": ("#e1d5e7", "#9673a6"),
    "sismo": ("#dae8fc", "#6c8ebf"),
    "dpa": ("#d5e8d4", "#82b366"),
    "censo": ("#ffe6cc", "#d79b00"),
    "analisis": ("#fff2cc", "#d6b656"),
    "ref": ("#eeeeee", "#9e9e9e"),
}


class Page:
    def __init__(self, name):
        self.name = name
        self.cells = []
        self.rows = {}
        self.n = 0

    def nid(self, prefix):
        self.n += 1
        return f"{prefix}{self.n}"

    def table(self, key, x, y, title, rows, color, width=None, subtitle=None):
        fill, stroke = COLORS[color]
        longest = max([len(title) * 8.2 + 20] + [len(name) * 7.1 + KEY_W + 18 for _, name in rows])
        w = int(width or max(190, longest))
        h = HEAD_H + ROW_H * len(rows)
        tid = self.nid("t")
        label = escape(title) if not subtitle else f"{escape(title)}<br><font style=\"font-size:10px;font-weight:normal\">{escape(subtitle)}</font>"
        self.cells.append(
            f'<mxCell id="{tid}" value={quoteattr(label)} style="shape=table;startSize={HEAD_H};container=1;'
            f'collapsible=0;childLayout=tableLayout;fixedRows=1;rowLines=0;fontStyle=1;align=center;'
            f'resizeLast=1;html=1;whiteSpace=wrap;fillColor={fill};strokeColor={stroke};swimlaneFillColor=#ffffff;'
            f'fontSize=13;fontFamily=Helvetica;arcSize=6;rounded=1;" vertex="1" parent="1">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')
        for i, (k, name) in enumerate(rows):
            rid = self.nid("r")
            last = i == len(rows) - 1
            self.cells.append(
                f'<mxCell id="{rid}" value="" style="shape=tableRow;horizontal=0;startSize=0;swimlaneHead=0;'
                f'swimlaneBody=0;fillColor=none;collapsible=0;dropTarget=0;points=[[0,0.5],[1,0.5]];'
                f'portConstraint=eastwest;top=0;left=0;right=0;bottom={0 if last else 1};strokeColor=#e6e6e6;" '
                f'vertex="1" parent="{tid}"><mxGeometry y="{HEAD_H + i * ROW_H}" width="{w}" height="{ROW_H}" '
                f'as="geometry"/></mxCell>')
            kcolor = "#b85450" if "PK" in k else ("#6c8ebf" if k else "#000000")
            self.cells.append(
                f'<mxCell id="{self.nid("c")}" value={quoteattr(k)} style="shape=partialRectangle;connectable=0;'
                f'fillColor=none;top=0;left=0;bottom=0;right=0;fontStyle=1;fontSize=10;fontColor={kcolor};'
                f'overflow=hidden;html=1;" vertex="1" parent="{rid}"><mxGeometry width="{KEY_W}" '
                f'height="{ROW_H}" as="geometry"><mxRectangle width="{KEY_W}" height="{ROW_H}" '
                f'as="alternateBounds"/></mxGeometry></mxCell>')
            geo = name.startswith("geom") or name.startswith("point") or name.startswith("footprint")
            style = "fontStyle=4;" if "PK" in k else ""
            fcolor = "#0b5394" if geo else "#1a1a1a"
            self.cells.append(
                f'<mxCell id="{self.nid("c")}" value={quoteattr(name)} style="shape=partialRectangle;'
                f'connectable=0;fillColor=none;top=0;left=0;bottom=0;right=0;align=left;spacingLeft=4;'
                f'fontSize=12;fontColor={fcolor};{style}overflow=hidden;html=1;" vertex="1" parent="{rid}">'
                f'<mxGeometry x="{KEY_W}" width="{w - KEY_W}" height="{ROW_H}" as="geometry">'
                f'<mxRectangle width="{w - KEY_W}" height="{ROW_H}" as="alternateBounds"/></mxGeometry></mxCell>')
            col = name.split(":")[0].split(" ")[0]
            self.rows[(key, col)] = rid
        return (x, y, w, h)

    def edge(self, src, dst, start="ERmandOne", end="ERmany", label=None, dashed=False, sides="rl", points=()):
        s = self.rows[src]
        t = self.rows[dst]
        lab = quoteattr(label or "")
        ex = 1 if sides[0] == "r" else 0
        en = 1 if sides[1] == "r" else 0
        pts = "".join(f'<mxPoint x="{px}" y="{py}"/>' for px, py in points)
        geom = (f'<mxGeometry relative="1" as="geometry"><Array as="points">{pts}</Array></mxGeometry>'
                if points else '<mxGeometry relative="1" as="geometry"/>')
        self.cells.append(
            f'<mxCell id="{self.nid("e")}" value={lab} style="edgeStyle=orthogonalEdgeStyle;rounded=1;'
            f'orthogonalLoop=1;html=1;endArrow={end};startArrow={start};endFill=0;startFill=0;strokeWidth=1.3;'
            f'strokeColor=#4d4d4d;fontSize=10;fontColor=#666666;labelBackgroundColor=#ffffff;'
            f'{"dashed=1;" if dashed else ""}jettySize=auto;exitX={ex};exitY=0.5;entryX={en};entryY=0.5;" '
            f'edge="1" parent="1" source="{s}" target="{t}">{geom}</mxCell>')

    def text(self, x, y, w, h, value, size=12, color="#333333", bold=False, italic=False, align="left"):
        st = (1 if bold else 0) + (2 if italic else 0)
        self.cells.append(
            f'<mxCell id="{self.nid("x")}" value={quoteattr(value)} style="text;html=1;whiteSpace=wrap;'
            f'align={align};verticalAlign=middle;fontSize={size};fontColor={color};fontStyle={st};" vertex="1" '
            f'parent="1"><mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')

    def zone(self, x, y, w, h, title, color):
        fill, stroke = COLORS[color]
        self.cells.append(
            f'<mxCell id="{self.nid("z")}" value={quoteattr(title)} style="rounded=1;arcSize=3;html=1;'
            f'fillColor={fill};opacity=35;strokeColor={stroke};dashed=1;verticalAlign=top;align=left;'
            f'spacingLeft=10;spacingTop=4;fontSize=13;fontStyle=3;fontColor={stroke};" vertex="1" parent="1">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/></mxCell>')

    def xml(self, idx):
        body = "".join(self.cells)
        return (f'<diagram id="pagina{idx}" name={quoteattr(self.name)}><mxGraphModel dx="1600" dy="900" grid="0" '
                f'gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="0" pageScale="1" '
                f'math="0" shadow="0"><root><mxCell id="0"/><mxCell id="1" parent="0"/>{body}</root>'
                f'</mxGraphModel></diagram>')


def legend(p, x, y):
    p.text(x, y, 560, 22,
           "<b>PK</b> llave primaria · <b>FK</b> llave foránea · <b>UQ</b> única · "
           "<font color='#0b5394'>azul</font>: columna geométrica (EPSG:4326)", size=11, color="#555555")
    p.text(x, y + 20, 560, 22,
           "Relaciones en notación pata de gallo: ─┼ uno · ─○┼ cero o uno · ─&lt; muchos", size=11, color="#555555")


# --------------------------------------------------------------------- pagina 1
p1 = Page("1. Datos cargados")
p1.text(40, 0, 1500, 34, "Modelo lógico: tablas con los datos cargados", size=20, bold=True, color="#1a1a1a")

p1.zone(20, 50, 330, 330, "Procedencia", "proc")
p1.zone(20, 400, 330, 470, "Magnitudes", "mag")
p1.zone(380, 50, 330, 820, "Sismos", "sismo")
p1.zone(740, 50, 330, 820, "Relaciones sismo–territorio", "sismo")
p1.zone(1100, 430, 330, 440, "División político-administrativa (DPA 2023)", "dpa")
p1.zone(1460, 50, 330, 820, "Zonas urbanas y población (Censo 2024)", "censo")

p1.table("ds", 50, 90, "data_source", [("PK", "source_code"), ("", "source_name"), ("", "citation")], "proc", 270)
p1.table("ir", 50, 240, "ingestion_run", [("PK", "ingestion_run_id"), ("FK", "source_code"), ("", "started_at"),
                                          ("", "status")], "proc", 270)
p1.table("mt", 50, 440, "magnitude_type", [("PK", "magnitude_type_code"), ("", "family"),
                                           ("", "is_moment_magnitude")], "mag", 270)
p1.table("mr", 50, 590, "magnitude_conversion_rule", [("PK FK", "source_code"), ("PK FK", "magnitude_type_code"),
                                                      ("FK", "conversion_method")], "mag", 270)
p1.table("mc", 50, 740, "magnitude_conversion", [("PK", "conversion_method"), ("", "slope, intercept"),
                                                 ("", "valid_min, valid_max")], "mag", 270)

p1.table("ev", 410, 250, "earthquake_event", [("PK", "earthquake_event_id"), ("FK", "source_code"),
                                              ("UQ", "source_event_id"), ("", "occurred_at"),
                                              ("", "magnitude, magnitude_type"), ("FK", "mw_method"),
                                              ("", "mw_homogenized"), ("", "depth_km"),
                                              ("", "geom: Point")], "sismo", 270, subtitle="59.534 sismos")
p1.text(410, 560, 270, 60,
        "<i>Vista</i> <b>v_event_location</b>: cada sismo con su comuna, provincia, región y Mw homogéneo "
        "(capa principal de QGIS).", size=11, color="#555555")

p1.table("eua", 770, 90, "event_urban_area", [("PK FK", "earthquake_event_id"), ("PK FK", "urban_area_id"),
                                              ("", "distance_rank"), ("", "epicentral_distance_km"),
                                              ("", "hypocentral_distance_km")], "sismo", 270)
p1.table("epe", 770, 330, "event_population_exposure", [("PK FK", "earthquake_event_id"),
                                                        ("", "population_25km / 50km / 100km"),
                                                        ("", "dwellings_adobe_50km")], "sismo", 270)
p1.table("eaa", 770, 560, "event_administrative_area", [("PK FK", "earthquake_event_id"),
                                                        ("PK FK", "administrative_area_id"),
                                                        ("", "assignment_method"), ("", "distance_km")], "sismo", 270)

p1.table("aa", 1130, 470, "administrative_area", [("PK", "administrative_area_id"), ("FK", "parent_area_id"),
                                                  ("", "level"), ("UQ", "official_code (CUT)"), ("", "name"),
                                                  ("", "geom: MultiPolygon")], "dpa", 270,
         subtitle="16 regiones · 56 provincias · 345 comunas")
p1.table("aap", 1130, 740, "administrative_area_part", [("PK", "administrative_area_part_id"),
                                                        ("FK", "administrative_area_id"), ("", "geom: Polygon")],
         "dpa", 270)

p1.table("ua", 1490, 90, "urban_area", [("PK", "urban_area_id"), ("FK", "commune_area_id"), ("UQ", "ine_entity_id"),
                                        ("", "name, category"), ("", "population"), ("", "geom: MultiPolygon")],
         "censo", 270, subtitle="592 ciudades y pueblos")
p1.table("uap", 1490, 345, "urban_area_part", [("PK", "urban_area_part_id"), ("FK", "urban_area_id"),
                                               ("", "geom: Polygon")], "censo", 270)
p1.table("cb", 1490, 520, "census_block", [("PK", "census_block_id"), ("FK", "urban_area_id"),
                                           ("FK", "commune_area_id"), ("UQ", "block_code"), ("", "population"),
                                           ("", "point: Point"), ("", "geom: MultiPolygon")], "censo", 270,
         subtitle="216.341 manzanas")

p1.edge(("ds", "source_code"), ("ir", "source_code"), sides="ll")
p1.edge(("ds", "source_code"), ("ev", "source_code"))
p1.edge(("ds", "source_code"), ("mr", "source_code"), sides="ll")
p1.edge(("mt", "magnitude_type_code"), ("mr", "magnitude_type_code"), sides="ll")
p1.edge(("mc", "conversion_method"), ("mr", "conversion_method"), sides="rr")
p1.edge(("mc", "conversion_method"), ("ev", "mw_method"), start="ERmandOne", end="ERzeroToMany")
p1.edge(("ev", "earthquake_event_id"), ("eua", "earthquake_event_id"))
p1.edge(("ev", "earthquake_event_id"), ("epe", "earthquake_event_id"), end="ERzeroToOne")
p1.edge(("ev", "earthquake_event_id"), ("eaa", "earthquake_event_id"), end="ERzeroToOne")
p1.edge(("aa", "administrative_area_id"), ("eaa", "administrative_area_id"), sides="lr")
p1.edge(("aa", "administrative_area_id"), ("aap", "administrative_area_id"), sides="ll")
p1.edge(("aa", "administrative_area_id"), ("aa", "parent_area_id"), start="ERzeroToOne", end="ERzeroToMany", sides="rr", points=((1420, 515), (1420, 541)))
p1.edge(("ua", "urban_area_id"), ("eua", "urban_area_id"), sides="lr")
p1.edge(("ua", "urban_area_id"), ("uap", "urban_area_id"), sides="rr", points=((1772, 135), (1772, 416)))
p1.edge(("ua", "urban_area_id"), ("cb", "urban_area_id"), start="ERzeroToOne", end="ERzeroToMany", sides="rr", points=((1784, 135), (1784, 591)))
p1.edge(("aa", "administrative_area_id"), ("ua", "commune_area_id"))
p1.edge(("aa", "administrative_area_id"), ("cb", "commune_area_id"))
legend(p1, 40, 885)

# --------------------------------------------------------------------- pagina 2
p2 = Page("2. Tablas de análisis")
p2.text(40, 0, 1300, 34, "Modelo lógico: tablas de análisis (se llenan en la entrega 3)", size=20, bold=True,
        color="#1a1a1a")
p2.zone(20, 50, 330, 360, "Magnitudes", "mag")
p2.zone(20, 430, 1050, 360, "Réplicas (declustering)", "analisis")
p2.zone(1100, 50, 330, 740, "Emparejamiento de fuentes e intensidad", "analisis")

p2.table("mt", 50, 90, "magnitude_type", [("PK", "magnitude_type_code"), ("", "family")], "ref", 270)
p2.table("me", 50, 210, "magnitude_estimate", [("PK FK", "earthquake_event_id"), ("PK FK", "magnitude_type_code"),
                                               ("PK", "agency"), ("", "magnitude_value"), ("", "origin")],
         "mag", 270, subtitle="104.225 magnitudes")
p2.table("ev", 470, 120, "earthquake_event", [("PK", "earthquake_event_id"), ("FK", "source_code"),
                                              ("", "occurred_at"), ("", "mw_homogenized"), ("", "geom: Point")],
         "ref", 270, subtitle="tabla de la página 1")
p2.table("ds", 50, 470, "data_source", [("PK", "source_code")], "ref", 270)
p2.table("dr", 50, 590, "declustering_run", [("PK", "declustering_run_id"), ("FK", "source_code"), ("", "method"),
                                             ("", "parameters (jsonb)"), ("", "minimum_magnitude")], "analisis", 270)
p2.table("ss", 410, 470, "seismic_sequence", [("PK", "seismic_sequence_id"), ("FK", "mainshock_event_id"),
                                              ("FK", "declustering_run_id"), ("", "aftershock_count"),
                                              ("", "largest_aftershock_magnitude"), ("", "footprint: Polygon")],
         "analisis", 280)
p2.table("er", 760, 470, "event_sequence_role", [("PK FK", "declustering_run_id"), ("PK FK", "earthquake_event_id"),
                                                 ("FK", "seismic_sequence_id"), ("", "role"),
                                                 ("", "distance_to_mainshock_km")], "analisis", 280)
p2.table("em", 1130, 90, "event_match", [("PK FK", "csn_event_id"), ("PK FK", "usgs_event_id"),
                                         ("", "time_difference_s"), ("", "distance_km"), ("", "match_score")],
         "analisis", 270)
p2.table("eis", 1130, 330, "event_impact_summary", [("PK FK", "earthquake_event_id"), ("", "max_mmi, max_cdi"),
                                                    ("", "pager_alert")], "analisis", 270)
p2.table("sc", 1130, 510, "shakemap_contour", [("PK", "shakemap_contour_id"), ("FK", "earthquake_event_id"),
                                               ("", "metric, contour_value"), ("", "geom: MultiPolygon")],
         "analisis", 270)

p2.edge(("mt", "magnitude_type_code"), ("me", "magnitude_type_code"), sides="ll")
p2.edge(("ev", "earthquake_event_id"), ("me", "earthquake_event_id"), sides="lr")
p2.edge(("ev", "earthquake_event_id"), ("em", "csn_event_id"), end="ERzeroToMany", points=((1110, 165), (1110, 135)))
p2.edge(("ev", "earthquake_event_id"), ("em", "usgs_event_id"), end="ERzeroToMany", points=((1110, 165), (1110, 161)))
p2.edge(("ev", "earthquake_event_id"), ("eis", "earthquake_event_id"), end="ERzeroToOne", points=((1090, 165), (1090, 375)))
p2.edge(("ev", "earthquake_event_id"), ("sc", "earthquake_event_id"), end="ERzeroToMany", points=((1090, 165), (1090, 581)))
p2.edge(("ds", "source_code"), ("dr", "source_code"), sides="ll")
p2.edge(("dr", "declustering_run_id"), ("ss", "declustering_run_id"), points=((380, 635), (380, 567)))
p2.edge(("dr", "declustering_run_id"), ("er", "declustering_run_id"), sides="rr", points=((360, 635), (360, 690), (1065, 690), (1065, 515)))
p2.edge(("ss", "seismic_sequence_id"), ("er", "seismic_sequence_id"), start="ERzeroToOne", end="ERzeroToMany", points=((705, 515), (705, 567)))
p2.edge(("ev", "earthquake_event_id"), ("ss", "mainshock_event_id"), end="ERzeroToMany", label="sismo principal", sides="ll", points=((440, 165), (440, 450), (395, 450), (395, 541)))
p2.edge(("ev", "earthquake_event_id"), ("er", "earthquake_event_id"), end="ERzeroToMany", points=((750, 165), (750, 541)))
p2.text(1130, 700, 290, 80, "Los contornos ShakeMap se cruzan con los puntos de <b>census_block</b> "
        "(ST_Covers) para contar la población expuesta a cada intensidad.", size=11, color="#555555")
legend(p2, 40, 805)

# --------------------------------------------------------------------- pagina 3
p3 = Page("3. Flujo de carga")


def node(page, key, x, y, w, h, value, kind):
    styles = {
        "src": "shape=document;boundedLbl=1;size=0.18;fillColor=#ffe6cc;strokeColor=#d79b00;",
        "proc": "rounded=1;arcSize=12;fillColor=#ffffff;strokeColor=#6c8ebf;strokeWidth=1.5;",
        "db": "shape=cylinder3;boundedLbl=1;backgroundOutline=1;size=12;fillColor=#dae8fc;strokeColor=#6c8ebf;",
    }
    nid = page.nid("n")
    page.cells.append(
        f'<mxCell id="{nid}" value={quoteattr(value)} style="{styles[kind]}whiteSpace=wrap;html=1;fontSize=14;'
        f'fontFamily=Helvetica;" vertex="1" parent="1"><mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" '
        f'as="geometry"/></mxCell>')
    page.rows[(key, "node")] = nid


def arrow(page, a, b, dashed=False, label="", points=(), exit_=None, entry=None):
    pts = "".join(f'<mxPoint x="{px}" y="{py}"/>' for px, py in points)
    geom = (f'<mxGeometry relative="1" as="geometry"><Array as="points">{pts}</Array></mxGeometry>'
            if points else '<mxGeometry relative="1" as="geometry"/>')
    ex = f"exitX={exit_[0]};exitY={exit_[1]};" if exit_ else ""
    en = f"entryX={entry[0]};entryY={entry[1]};" if entry else ""
    color = "#999999" if dashed else "#4d4d4d"
    page.cells.append(
        f'<mxCell id="{page.nid("a")}" value={quoteattr(label)} style="edgeStyle=orthogonalEdgeStyle;rounded=1;'
        f'html=1;endArrow=block;endFill=1;strokeWidth={1.3 if dashed else 1.8};strokeColor={color};fontSize=13;'
        f'fontStyle=2;fontColor=#666666;labelBackgroundColor=#ffffff;{"dashed=1;" if dashed else ""}{ex}{en}" '
        f'edge="1" parent="1" source="{page.rows[(a, "node")]}" target="{page.rows[(b, "node")]}">{geom}</mxCell>')


p3.text(20, 0, 960, 34, "Flujo de carga de los datos", size=20, bold=True, color="#1a1a1a")
p3.text(20, 32, 960, 26, "Cada fuente pasa primero por un esquema temporal; cada paso SQL corre en una transacción "
        "y registra la carga en <b>ingestion_run</b>.", size=13, color="#555555")
p3.zone(20, 70, 300, 650, "Sismos (CSN y USGS)", "sismo")
p3.zone(345, 70, 300, 650, "División político-administrativa", "dpa")
p3.zone(670, 70, 300, 650, "Censo 2024 (INE)", "censo")

W, H = 260, 84
cols = {"s": 40, "d": 365, "c": 690}
ys = [110, 225, 335, 445, 560]
node(p3, "s0", cols["s"], ys[0], W, H, "<b>CSN</b>: CSV histórico y páginas diarias<br><b>USGS</b>: API GeoJSON", "src")
node(p3, "s1", cols["s"], ys[1], W, H, "<b>Python</b><br>descarga, caché y normalización a CSV", "proc")
node(p3, "s2", cols["s"], ys[2], W, H, "<b>load_catalogs.sql</b><br>UPSERT por fuente e id de origen", "proc")
node(p3, "s3", cols["s"], ys[3], W, H, "<b>homogenize_magnitudes.sql</b><br>Mw homogéneo y todas las magnitudes", "proc")
node(p3, "s4", cols["s"], ys[4], W, 120, "<b>earthquake_event</b><br>magnitude_estimate<br><font style='font-size:12px'>59.534 sismos</font>", "db")

node(p3, "d0", cols["d"], ys[0], W, H, "<b>DPA 2023</b> (SUBDERE)<br>shapefile · EPSG:5360", "src")
node(p3, "d1", cols["d"], ys[1], W, H, "<b>shp2pgsql</b><br>esquema temporal dpa_staging", "proc")
node(p3, "d2", cols["d"], ys[2], W, H, "<b>load_dpa.sql</b><br>5360 → 4326, validación, jerarquía y ST_Subdivide", "proc")
node(p3, "d3", cols["d"], ys[3], W, H, "<b>assign_event_areas.sql</b><br>comuna de cada sismo (covers / nearest)", "proc")
node(p3, "d4", cols["d"], ys[4], W, 120, "<b>administrative_area</b><br>administrative_area_part<br>event_administrative_area", "db")

node(p3, "c0", cols["c"], ys[0], W, H, "<b>Censo 2024</b> (INE)<br>GeoParquet · EPSG:4674", "src")
node(p3, "c1", cols["c"], ys[1], W, H, "<b>ogr2ogr</b> (GDAL de QGIS)<br>esquema temporal ine_staging", "proc")
node(p3, "c2", cols["c"], ys[2], W, H, "<b>load_census.sql</b><br>validación, UPSERT y ST_Subdivide", "proc")
node(p3, "c3", cols["c"], ys[3], W, H, "<b>assign_urban_exposure.sql</b><br>zona urbana cercana y población", "proc")
node(p3, "c4", cols["c"], ys[4], W, 120, "<b>urban_area</b>, census_block<br>event_urban_area<br>event_population_exposure", "db")

for col in "sdc":
    for i in range(4):
        arrow(p3, f"{col}{i}", f"{col}{i + 1}", exit_=(0.5, 1), entry=(0.5, 0))
arrow(p3, "s3", "d3", dashed=True, label="sismos", exit_=(1, 0.5), entry=(0, 0.5))
arrow(p3, "d2", "c2", dashed=True, label="comunas", exit_=(1, 0.5), entry=(0, 0.5))
arrow(p3, "s4", "c3", dashed=True, label="sismos", exit_=(0.5, 1), entry=(1, 0.5),
      points=((170, 700), (995, 700), (995, 487)))
p3.text(20, 735, 960, 40,
        "<font color='#d79b00'>■</font> fuente oficial   <font color='#6c8ebf'>□</font> proceso (script)   "
        "<font color='#6c8ebf'>⛁</font> tablas en PostGIS   - - → dependencia: el paso necesita datos de otra columna",
        size=12, color="#555555")

xml = (f'<mxfile host="build_drawio_model.py" version="24.0.0">{p1.xml(1)}{p2.xml(2)}{p3.xml(3)}</mxfile>')
OUT.write_text(xml, encoding="utf-8")
print("ok", OUT)
