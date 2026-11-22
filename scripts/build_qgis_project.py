"""Genera el proyecto QGIS qgis/sismos_chile_v2.qgs a partir de la base local.

Uso (desde la carpeta del proyecto, con la base encendida):

    "C:\\Program Files\\QGIS 3.44.13\\bin\\python-qgis-ltr.bat" scripts\\build_qgis_project.py

Lee la conexion desde .env. La contrasena se usa solo para leer las capas
mientras se arma el proyecto: el archivo final NO la contiene, y QGIS la pide
una vez al abrirlo.
"""

import os
import re
import sys
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from qgis.core import (  # noqa: E402
    Qgis,
    QgsApplication,
    QgsBookmark,
    QgsCoordinateReferenceSystem,
    QgsCoordinateTransform,
    QgsDataSourceUri,
    QgsFillSymbol,
    QgsGradientColorRamp,
    QgsGraduatedSymbolRenderer,
    QgsHeatmapRenderer,
    QgsLayoutItemLabel,
    QgsLayoutItemLegend,
    QgsLayoutItemMap,
    QgsLayoutItemPage,
    QgsLayoutItemScaleBar,
    QgsLayoutPoint,
    QgsLayoutSize,
    QgsLineSymbol,
    QgsMarkerSymbol,
    QgsPalLayerSettings,
    QgsPrintLayout,
    QgsProject,
    QgsProperty,
    QgsRasterLayer,
    QgsRectangle,
    QgsReferencedRectangle,
    QgsRendererRange,
    QgsSingleSymbolRenderer,
    QgsTextBufferSettings,
    QgsTextFormat,
    QgsUnitTypes,
    QgsVectorLayer,
    QgsVectorLayerSimpleLabeling,
)
from qgis.PyQt.QtCore import QRectF  # noqa: E402
from qgis.PyQt.QtGui import QColor, QFont  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "qgis" / "sismos_chile_v2.qgs"
QGIS_PREFIX = os.environ.get("QGIS_PREFIX_PATH", r"C:\Program Files\QGIS 3.44.13\apps\qgis-ltr")


def read_env():
    values = {}
    for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key.strip()] = value.strip()
    return values


ENV = read_env()
DB = ENV.get("POSTGRES_DB", "sismos_chile")
USER = ENV.get("POSTGRES_USER", "sismos_app")
PORT = ENV.get("POSTGRES_PORT", "5433")
PASSWORD = ENV["POSTGRES_PASSWORD"]

WGS84 = QgsCoordinateReferenceSystem("EPSG:4326")
WEB = QgsCoordinateReferenceSystem("EPSG:3857")

YLORRD5 = ["#ffffb2", "#fecc5c", "#fd8d3c", "#f03b20", "#bd0026"]
REDS5 = ["#fee5d9", "#fcae91", "#fb6a4a", "#de2d26", "#a50f15"]


# ---------------------------------------------------------------- capas
def pg_layer(name, table=None, sql=None, key=None, where="", geom_type=None):
    uri = QgsDataSourceUri()
    uri.setConnection("127.0.0.1", PORT, DB, USER, PASSWORD)
    if sql:
        uri.setDataSource("", f"({sql})", "geom", where, key)
    else:
        uri.setDataSource("seismic", table, "geom", where, key or "")
    uri.setSrid("4326")
    if geom_type is not None:
        uri.setWkbType(geom_type)
    layer = QgsVectorLayer(uri.uri(False), name, "postgres")
    if not layer.isValid():
        sys.exit(f"Capa invalida: {name}")
    return layer


def graduated(field, ranges):
    renderer = QgsGraduatedSymbolRenderer(field, [QgsRendererRange(lo, hi, sym, label) for lo, hi, sym, label in ranges])
    return renderer


def fill(color, outline="no", outline_color="#ffffff", width="0.1", opacity=1.0):
    sym = QgsFillSymbol.createSimple(
        {"color": color, "outline_style": outline, "outline_color": outline_color, "outline_width": width}
    )
    sym.setOpacity(opacity)
    return sym


def marker(color, size, outline="#ffffff"):
    return QgsMarkerSymbol.createSimple(
        {"name": "circle", "color": color, "outline_color": outline, "outline_width": "0.2", "size": str(size)}
    )


def labels(layer, field, size=8, show_expr=None, bold=False):
    settings = QgsPalLayerSettings()
    settings.fieldName = field
    settings.enabled = True
    fmt = QgsTextFormat()
    font = QFont("Arial")
    font.setBold(bold)
    fmt.setFont(font)
    fmt.setSize(size)
    buffer = QgsTextBufferSettings()
    buffer.setEnabled(True)
    buffer.setSize(0.8)
    buffer.setColor(QColor("white"))
    fmt.setBuffer(buffer)
    settings.setFormat(fmt)
    if show_expr:
        show = getattr(QgsPalLayerSettings, "Show", None) or QgsPalLayerSettings.Property.Show
        settings.dataDefinedProperties().setProperty(show, QgsProperty.fromExpression(show_expr))
    layer.setLabeling(QgsVectorLayerSimpleLabeling(settings))
    layer.setLabelsEnabled(True)


def text_format(size, bold=False):
    fmt = QgsTextFormat()
    font = QFont("Arial")
    font.setBold(bold)
    fmt.setFont(font)
    fmt.setSize(size)
    return fmt


def visible_below(layer, scale):
    """Solo se dibuja con zoom mayor que 1:scale."""
    layer.setScaleBasedVisibility(True)
    layer.setMinimumScale(scale)
    layer.setMaximumScale(1)


def build_layers():
    layers = {}

    # Mapa base
    osm = QgsRasterLayer(
        "type=xyz&url=https://tile.openstreetmap.org/{z}/{x}/{y}.png&zmax=19&zmin=0",
        "OpenStreetMap",
        "wms",
    )
    layers["osm"] = osm

    # DPA
    regiones = pg_layer("Regiones", "administrative_area", key="administrative_area_id", where="level = 'region'")
    regiones.setRenderer(QgsSingleSymbolRenderer(fill("0,0,0,0", "solid", "#3c3c3c", "0.5")))
    labels(regiones, "name", size=9, bold=True)
    layers["regiones"] = regiones

    comunas = pg_layer("Comunas", "administrative_area", key="administrative_area_id", where="level = 'commune'")
    comunas.setRenderer(QgsSingleSymbolRenderer(fill("0,0,0,0", "solid", "#8c8c8c", "0.2")))
    visible_below(comunas, 2_000_000)
    layers["comunas"] = comunas

    # Censo 2024
    zonas = pg_layer("Zonas urbanas (población)", "urban_area", key="urban_area_id")
    breaks = [(0, 5000, "Menos de 5.000"), (5000, 20000, "5.000 - 20.000"), (20000, 100000, "20.000 - 100.000"),
              (100000, 250000, "100.000 - 250.000"), (250000, 1_000_000, "Más de 250.000")]
    zonas.setOpacity(0.85)
    zonas.setRenderer(graduated("population", [
        (lo, hi, fill(c, "solid", "#7f2704", "0.1"), lab) for (lo, hi, lab), c in zip(breaks, YLORRD5)
    ]))
    labels(zonas, "name", size=8, show_expr='"population" >= 50000')
    layers["zonas"] = zonas

    manzanas = pg_layer("Manzanas (personas por manzana)", "census_block", key="census_block_id")
    zero = fill("#bdbdbd", opacity=0.35)
    block_breaks = [(1, 30, "1 - 30"), (30, 70, "31 - 70"), (70, 150, "71 - 150"), (150, 500, "151 - 500"),
                    (500, 20000, "Más de 500")]
    manzanas.setRenderer(graduated("population", [(0, 0, zero, "Sin población o sin datos")] + [
        (lo, hi, fill(c), lab) for (lo, hi, lab), c in zip(block_breaks, YLORRD5)
    ]))
    visible_below(manzanas, 100_000)
    layers["manzanas"] = manzanas

    ciudades_sql = """
        SELECT u.urban_area_id, u.name, u.category, u.population,
               count(e.earthquake_event_id) AS sismos_mw5_100km, u.geom
        FROM seismic.urban_area u
        LEFT JOIN seismic.event_urban_area l
               ON l.urban_area_id = u.urban_area_id AND l.hypocentral_distance_km <= 100
        LEFT JOIN seismic.earthquake_event e
               ON e.earthquake_event_id = l.earthquake_event_id AND e.mw_homogenized >= 5
        GROUP BY u.urban_area_id"""
    ciudades = pg_layer("Ciudades: sismos Mw ≥ 5 a ≤ 100 km", sql=ciudades_sql, key="urban_area_id",
                        geom_type=Qgis.WkbType.MultiPolygon)
    c_breaks = [(0, 0, "Ninguno"), (1, 25, "1 - 25"), (25, 100, "26 - 100"), (100, 250, "101 - 250"),
                (250, 1000, "Más de 250")]
    ciudades.setRenderer(graduated("sismos_mw5_100km", [
        (lo, hi, fill(c, "solid", "#67000d", "0.1"), lab) for (lo, hi, lab), c in zip(c_breaks, REDS5)
    ]))
    labels(ciudades, "name", size=8, show_expr='"sismos_mw5_100km" >= 300')
    layers["ciudades"] = ciudades

    # Sismos
    sismos = pg_layer("Sismos Mw ≥ 5", "v_event_location", key="earthquake_event_id",
                      where="mw_homogenized >= 5", geom_type=Qgis.WkbType.Point)
    m_breaks = [(5, 6, "Mw 5 - 6", 1.4), (6, 7, "Mw 6 - 7", 2.6), (7, 8, "Mw 7 - 8", 4.5), (8, 10, "Mw 8 o más", 7.5)]
    sismos.setRenderer(graduated("mw_homogenized", [
        (lo, hi, marker("#d7301f", size), lab) for lo, hi, lab, size in m_breaks
    ]))
    temporal = sismos.temporalProperties()
    temporal.setIsActive(True)
    try:
        temporal.setMode(Qgis.VectorTemporalMode.FeatureDateTimeInstantFromField)
    except AttributeError:
        temporal.setMode(temporal.ModeFeatureDateTimeInstantFromField)
    temporal.setStartField("occurred_at")
    layers["sismos"] = sismos

    todos = pg_layer("Todos los sismos (mapa de calor)", "v_event_location", key="earthquake_event_id",
                     geom_type=Qgis.WkbType.Point)
    heat = QgsHeatmapRenderer()
    heat.setRadius(6)
    heat.setRadiusUnit(QgsUnitTypes.RenderMillimeters)
    ramp = QgsGradientColorRamp(QColor(255, 255, 178, 0), QColor("#bd0026"))
    heat.setColorRamp(ramp)
    todos.setRenderer(heat)
    layers["todos"] = todos

    poblacion_sql = """
        SELECT e.earthquake_event_id, e.occurred_at, e.mw_homogenized, e.depth_km,
               x.population_25km, x.population_50km, x.population_100km, e.geom
        FROM seismic.earthquake_event e
        JOIN seismic.event_population_exposure x USING (earthquake_event_id)"""
    poblacion = pg_layer("Sismos Mw ≥ 5: población a 50 km", sql=poblacion_sql, key="earthquake_event_id",
                         geom_type=Qgis.WkbType.Point)
    p_breaks = [(0, 0, "Nadie", 0.8, "#bdbdbd"), (1, 50000, "Hasta 50 mil", 1.5, "#fdae6b"),
                (50000, 500000, "50 mil - 500 mil", 3, "#f16913"),
                (500000, 2_000_000, "500 mil - 2 millones", 5, "#d94801"),
                (2_000_000, 20_000_000, "Más de 2 millones", 8, "#8c2d04")]
    poblacion.setRenderer(graduated("population_50km", [
        (lo, hi, marker(color, size), lab) for lo, hi, lab, size, color in p_breaks
    ]))
    layers["poblacion"] = poblacion

    lineas_sql = """
        SELECT e.earthquake_event_id AS id, e.occurred_at, e.mw_homogenized, u.name AS ciudad,
               l.epicentral_distance_km,
               ST_MakeLine(e.geom, ST_ClosestPoint(u.geom, e.geom)) AS geom
        FROM seismic.event_urban_area l
        JOIN seismic.earthquake_event e USING (earthquake_event_id)
        JOIN seismic.urban_area u USING (urban_area_id)
        WHERE l.distance_rank = 1 AND e.mw_homogenized >= 7"""
    lineas = pg_layer("Mw ≥ 7: línea a zona urbana", sql=lineas_sql, key="id",
                      geom_type=Qgis.WkbType.LineString)
    lineas.setRenderer(QgsSingleSymbolRenderer(QgsLineSymbol.createSimple(
        {"line_color": "#a50f15", "line_width": "0.5", "line_style": "dash"})))
    labels(lineas, "ciudad", size=7)
    layers["lineas"] = lineas

    return layers


# ------------------------------------------------------------- proyecto
def to_web(rect):
    return QgsCoordinateTransform(WGS84, WEB, QgsProject.instance()).transformBoundingBox(rect)


def padded(xmin, ymin, xmax, ymax, pad):
    return QgsRectangle(xmin - pad, ymin - pad, xmax + pad, ymax + pad)


def main():
    app = QgsApplication([], False)
    QgsApplication.setPrefixPath(QGIS_PREFIX, True)
    app.initQgis()

    project = QgsProject.instance()
    project.setTitle("Sismicidad de Chile - modelo v2")
    project.setCrs(WEB)
    layers = build_layers()

    root = project.layerTreeRoot()
    tree = [
        ("Sismos", ["lineas", "sismos", "poblacion", "todos"]),
        ("Censo 2024", ["manzanas", "zonas", "ciudades"]),
        ("Límites DPA 2023", ["regiones", "comunas"]),
        ("Mapa base", ["osm"]),
    ]
    hidden = {"poblacion", "todos", "ciudades"}
    for group_name, keys in tree:
        group = root.addGroup(group_name)
        for key in keys:
            project.addMapLayer(layers[key], False)
            node = group.addLayer(layers[key])
            node.setItemVisibilityChecked(key not in hidden)
            if key in hidden:
                node.setExpanded(False)

    chile = QgsRectangle(-76.5, -56.5, -65.5, -17.0)
    project.viewSettings().setDefaultViewExtent(QgsReferencedRectangle(to_web(chile), WEB))

    bookmarks = [
        ("1. Chile completo", chile),
        ("2. Calama: comuna vs ciudad", padded(-69.19, -23.14, -67.92, -21.06, 0.1)),
        ("3. Litoral central", padded(-71.71, -33.63, -71.47, -32.94, 0.15)),
        ("4. Valdivia 1960 -> Contulmo", padded(-73.41, -38.14, -73.23, -38.03, 0.15)),
        ("5. Santiago centro (manzanas)", QgsRectangle(-70.675, -33.465, -70.625, -33.425)),
    ]
    for name, rect in bookmarks:
        bm = QgsBookmark()
        bm.setName(name)
        bm.setGroup("Sismos v2")
        bm.setExtent(QgsReferencedRectangle(to_web(rect), WEB))
        project.bookmarkManager().addBookmark(bm)

    # Composicion de impresion A4 vertical
    layout = QgsPrintLayout(project)
    layout.initializeDefaults()
    layout.setName("Mapa Chile A4")
    layout.pageCollection().page(0).setPageSize("A4", QgsLayoutItemPage.Orientation.Portrait)

    title = QgsLayoutItemLabel(layout)
    title.setText("Sismos Mw ≥ 5 y zonas urbanas de Chile")
    title.setTextFormat(text_format(16, bold=True))
    layout.addLayoutItem(title)
    title.attemptMove(QgsLayoutPoint(10, 8))
    title.attemptResize(QgsLayoutSize(190, 10))


    map_item = QgsLayoutItemMap(layout)
    map_item.attemptSetSceneRect(QRectF(10, 22, 110, 250))
    utm = QgsCoordinateReferenceSystem("EPSG:32719")
    map_item.setCrs(utm)
    map_item.zoomToExtent(QgsCoordinateTransform(WGS84, utm, project).transformBoundingBox(
        QgsRectangle(-76.0, -56.0, -66.0, -17.5)))
    map_item.setFrameEnabled(True)
    layout.addLayoutItem(map_item)

    legend = QgsLayoutItemLegend(layout)
    legend.setTitle("Leyenda")
    legend.setLinkedMap(map_item)
    legend.setLegendFilterByMapEnabled(True)
    layout.addLayoutItem(legend)
    legend.attemptMove(QgsLayoutPoint(125, 22))

    scalebar = QgsLayoutItemScaleBar(layout)
    scalebar.setStyle("Single Box")
    scalebar.setLinkedMap(map_item)
    scalebar.applyDefaultSize()
    scalebar.setUnits(Qgis.DistanceUnit.Kilometers)
    scalebar.setUnitLabel("km")
    scalebar.setNumberOfSegmentsLeft(0)
    scalebar.setNumberOfSegments(2)
    scalebar.setUnitsPerSegment(250)
    scalebar.setSegmentSizeMode(Qgis.ScaleBarSegmentSizeMode.Fixed)
    layout.addLayoutItem(scalebar)
    scalebar.attemptMove(QgsLayoutPoint(125, 230))

    note = QgsLayoutItemLabel(layout)
    note.setText(
        "Fuentes: CSN, USGS; INE, Censo de Población y Vivienda 2024, Base Cartográfica Censal; "
        "SUBDERE, DPA 2023.\n"
        "Autorizada su circulación por Resolución Nº 87 del 2023 de la Dirección Nacional de "
        "Fronteras y Límites del Estado.\n"
        "Magnitud: Mw homogéneo (mw_homogenized). Proyección: WGS 84 / UTM 19S."
    )
    note.setTextFormat(text_format(7))
    layout.addLayoutItem(note)
    note.attemptMove(QgsLayoutPoint(125, 245))
    note.attemptResize(QgsLayoutSize(78, 40))
    project.layoutManager().addLayout(layout)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    if not project.write(str(OUT)):
        sys.exit("No se pudo escribir el proyecto")

    # Quitar la contrasena del archivo: QGIS la pedira al abrir.
    text = OUT.read_text(encoding="utf-8")
    text = re.sub(r"\s*password='(?:[^'\\]|\\.)*'", "", text)
    text = re.sub(r"\s*password=&apos;.*?&apos;", "", text)
    if PASSWORD in text:
        OUT.unlink()
        sys.exit("La contrasena seguia en el proyecto; se borro el archivo.")
    OUT.write_text(text, encoding="utf-8")

    print(f"Proyecto escrito en {OUT}")
    print("Capas:", ", ".join(layer.name() for layer in project.mapLayers().values()))
    app.exitQgis()


if __name__ == "__main__":
    main()
