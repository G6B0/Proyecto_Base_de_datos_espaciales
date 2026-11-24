# Test de Knox: interacción espacio-tiempo antes y después de quitar réplicas

**Fecha:** 2026-11-23 · **Script:** `scripts/knox_test.py` · **Resultados:** `knox.json` · **Figura:** `docs/img/replicas/07_knox.png`

## Para qué

Validar el declustering (paso 3) con un método de la materia: el **test de Knox** (diapositiva 95, *Spatio-Temporal & Event-Based Spatial*). Si quitar réplicas funciona, los sismos que quedan no deberían estar cerca en espacio **y** tiempo más de lo que daría el azar.

## Método

1. Para cada par de sismos a **δ** km o menos (distancia sobre la esfera) se mira si además están a **τ** días o menos. El conteo de esos pares es el estadístico **X**.
2. Hipótesis nula (sin interacción): se **barajan las fechas** entre los epicentros. Así se conserva dónde ocurren los sismos y cuántos hay cada año, pero se rompe la relación entre lugar y momento.
3. Con **999 permutaciones** (semilla 20261123): esperado = media de X simulado; razón = X / esperado; p (una cola) = (1 + nº de simulaciones ≥ X) / 1000 para "más pares que el azar", y la cola opuesta para "menos pares".
4. Escalas: δ = 10, 25 y 50 km; τ = 1, 10 y 100 días (9 combinaciones por catálogo).
5. Catálogos (sismos Mw ≥ 4 desde 1960, sin duplicados CSN–USGS): completo (44.950), sin réplicas según Gardner-Knopoff (16.621) y sin réplicas según ST-DBSCAN (33.394).

Los pares cercanos se buscan con un árbol k-d (`scipy.spatial.cKDTree`) sobre coordenadas 3D: el catálogo completo tiene 15 millones de pares a 50 km o menos. Tarda unos 5 minutos en total.

## Resultados (razón observado / esperado)

| δ | τ | Completo | Sin réplicas (GK) | Sin réplicas (ST-DBSCAN) |
|---:|---:|---:|---:|---:|
| 10 km | 1 día | **22,2** | 0,0 ↓ | 12,6 |
| 10 km | 10 días | **11,0** | 0,0 ↓ | 3,2 |
| 10 km | 100 días | **4,6** | 0,8 ↓ | 1,7 |
| 25 km | 1 día | **15,0** | 0,0 ↓ | 5,3 |
| 25 km | 10 días | **8,5** | 0,0 ↓ | 1,9 |
| 25 km | 100 días | **3,9** | 0,7 ↓ | 1,4 |
| 50 km | 1 día | **10,8** | 1,00 (p = 0,52) | 2,8 |
| 50 km | 10 días | **6,8** | 0,7 ↓ | 1,4 |
| 50 km | 100 días | **3,4** | 0,9 ↓ | 1,3 |

Todas las razones son significativas con p ≤ 0,001 (↓ = significativamente **menos** pares que el azar, p ≤ 0,01), salvo Gardner-Knopoff a 50 km y 1 día, que es indistinguible del azar (p = 0,52). Con 27 pruebas, la corrección de Bonferroni exige p ≤ 0,0019; todas las significativas la cumplen salvo GK a 10 km y 1 día (p = 0,010).

## Lectura

1. **El catálogo completo tiene fuerte interacción espacio-tiempo:** hay 22 veces más pares a 10 km y 1 día de lo esperable. La interacción decrece con τ y con δ, como se espera de las réplicas (Omori: decaen con el tiempo; se concentran cerca de la ruptura).
2. **ST-DBSCAN deja interacción residual significativa** en todas las escalas (de 12,6 a 1,3). Encadena bien las secuencias grandes, pero con 40 km y 10 días fijos deja como "independientes" réplicas de sismos chicos y réplicas tardías.
3. **Gardner-Knopoff elimina la interacción, e incluso la invierte** (razón < 1). Hay que leerlo con cuidado: sus ventanas (30 km y 41 días para un Mw 4; 118 km y 2,9 años para el Maule) son **más grandes que varias escalas del test**, así que vacían esas vecindades **por construcción**. Es en parte circular. Lo informativo es que la interacción no reaparece en ninguna escala, y que a 50 km y 1 día, donde el método no fuerza nada para la mayoría de los sismos, el resultado es exactamente el azar (1,00).
4. **Gardner-Knopoff tiende a quitar de más.** La razón < 1 a 10 y 100 días indica que el catálogo sin réplicas queda más espaciado que un proceso al azar. Es una crítica conocida del método (ventanas amplias que se llevan sismos independientes), y es el costo de no dejar réplicas.

## Conclusión para el informe

Los dos métodos ubican al catálogo a los dos lados del azar: **ST-DBSCAN queda corto** (deja réplicas) y **Gardner-Knopoff se pasa un poco** (quita algunos sismos independientes). Para estudiar la sismicidad de fondo usamos Gardner-Knopoff, que es el estándar sismológico y cumple la ley de Båth (1,19), sabiendo que es conservador. Como dice la materia, el resultado del test depende de las escalas elegidas: por eso se reportan nueve combinaciones y no una.
