# Estado del port → ver `../CLAUDE.md`

El estado de las fases, lo que falta de cada una, el detalle de la Fase 4
en curso y las referencias Swift de cada pieza viven ahora en
**`CLAUDE.md`**, en la raíz del repo.

Está ahí y no aquí por una razón concreta: `CLAUDE.md` se carga
automáticamente en el contexto de un agente, así que la orientación llega
sin que nadie tenga que acordarse de buscarla. Mantener una segunda copia
en este archivo garantizaría que las dos se separen — exactamente el modo
de falla que este port documenta en varios sitios (las tres copias de
world-to-screen que ya discrepaban entre sí).

| Buscas | Está en |
|---|---|
| Fases, pendientes, plan de Fase 4, convenciones | `../CLAUDE.md` |
| El porqué detallado de cada decisión y divergencia | `ROADMAP.md` |
| Qué porta un archivo y qué dejó fuera | La cabecera de ese archivo |
