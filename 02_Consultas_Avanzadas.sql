-- =====================================================================
-- 02_Consultas_Avanzadas.sql
-- 20 consultas de análisis y reporteo (MySQL 8.0: CTEs y funciones de ventana)
-- Convención: las ventas 'Cancelado' NO cuentan como ingreso.
-- =====================================================================
USE ecommerce_db;

-- 1. Top 10 Productos Más Vendidos (por ingresos generados)
SELECT p.id_producto, p.nombre,
       SUM(d.cantidad)                              AS unidades_vendidas,
       SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos
FROM detalle_ventas d
JOIN ventas v    ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
JOIN productos p ON p.id_producto = d.id_producto
GROUP BY p.id_producto, p.nombre
ORDER BY ingresos DESC
LIMIT 10;

-- 2. Productos con Bajas Ventas (10% inferior de ingresos; incluye productos sin ventas)
SELECT id_producto, nombre, ingresos
FROM (
  SELECT p.id_producto, p.nombre,
         COALESCE(SUM(d.cantidad * d.precio_unitario_congelado), 0) AS ingresos,
         PERCENT_RANK() OVER (ORDER BY COALESCE(SUM(d.cantidad * d.precio_unitario_congelado), 0)) AS pr
  FROM productos p
  LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
  LEFT JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
  WHERE p.activo = 1
  GROUP BY p.id_producto, p.nombre
) t
WHERE pr <= 0.10
ORDER BY ingresos;

-- 3. Clientes VIP: 5 clientes con mayor valor de vida (LTV = gasto total histórico)
SELECT c.id_cliente, CONCAT(c.nombre, ' ', c.apellido) AS cliente, c.email,
       COUNT(v.id_venta) AS compras, SUM(v.total) AS ltv
FROM clientes c
JOIN ventas v ON v.id_cliente = c.id_cliente AND v.estado <> 'Cancelado'
GROUP BY c.id_cliente, c.nombre, c.apellido, c.email
ORDER BY ltv DESC
LIMIT 5;

-- 4. Análisis de Ventas Mensuales (agrupadas por año y mes)
SELECT YEAR(fecha_venta) AS anio, MONTH(fecha_venta) AS mes,
       COUNT(*) AS num_ventas, SUM(total) AS ventas_totales, ROUND(AVG(total), 2) AS ticket_promedio
FROM ventas
WHERE estado <> 'Cancelado'
GROUP BY YEAR(fecha_venta), MONTH(fecha_venta)
ORDER BY anio, mes;

-- 5. Crecimiento de Clientes: nuevos clientes registrados por trimestre
SELECT YEAR(fecha_registro) AS anio, QUARTER(fecha_registro) AS trimestre, COUNT(*) AS nuevos_clientes
FROM clientes
GROUP BY YEAR(fecha_registro), QUARTER(fecha_registro)
ORDER BY anio, trimestre;

-- 6. Tasa de Compra Repetida: % de clientes compradores con más de una compra
SELECT COUNT(*) AS clientes_compradores,
       SUM(compras > 1) AS clientes_recurrentes,
       ROUND(100 * SUM(compras > 1) / COUNT(*), 2) AS pct_compra_repetida
FROM (
  SELECT id_cliente, COUNT(*) AS compras
  FROM ventas WHERE estado <> 'Cancelado'
  GROUP BY id_cliente
) t;

-- 7. Productos Comprados Juntos Frecuentemente (pares en la misma venta)
SELECT p1.nombre AS producto_a, p2.nombre AS producto_b, COUNT(*) AS veces_juntos
FROM detalle_ventas a
JOIN detalle_ventas b ON b.id_venta = a.id_venta AND a.id_producto < b.id_producto
JOIN ventas v ON v.id_venta = a.id_venta AND v.estado <> 'Cancelado'
JOIN productos p1 ON p1.id_producto = a.id_producto
JOIN productos p2 ON p2.id_producto = b.id_producto
GROUP BY a.id_producto, b.id_producto, p1.nombre, p2.nombre
HAVING COUNT(*) >= 2
ORDER BY veces_juntos DESC, producto_a
LIMIT 15;

-- 8. Rotación de Inventario por categoría (últimos 12 meses)
--    Rotación = costo de lo vendido / valor actual del inventario (a costo)
SELECT c.nombre AS categoria,
       COALESCE(SUM(vend.costo_vendido), 0)  AS costo_vendido_12m,
       SUM(p.stock * p.costo)                AS valor_inventario,
       ROUND(COALESCE(SUM(vend.costo_vendido), 0) / NULLIF(SUM(p.stock * p.costo), 0), 2) AS rotacion
FROM categorias c
JOIN productos p ON p.id_categoria = c.id_categoria
LEFT JOIN (
  SELECT d.id_producto, SUM(d.cantidad * pr.costo) AS costo_vendido
  FROM detalle_ventas d
  JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
                AND v.fecha_venta >= DATE_SUB(CURDATE(), INTERVAL 12 MONTH)
  JOIN productos pr ON pr.id_producto = d.id_producto
  GROUP BY d.id_producto
) vend ON vend.id_producto = p.id_producto
GROUP BY c.id_categoria, c.nombre
ORDER BY rotacion DESC;

-- 9. Productos que Necesitan Reabastecimiento (stock por debajo del umbral mínimo)
SELECT p.id_producto, p.nombre, p.stock, p.stock_minimo,
       (p.stock_minimo - p.stock) AS faltante, pr.nombre AS proveedor, pr.email_contacto
FROM productos p
JOIN proveedores pr ON pr.id_proveedor = p.id_proveedor
WHERE p.activo = 1 AND p.stock < p.stock_minimo
ORDER BY faltante DESC;

-- 10. Análisis de Carrito Abandonado (simulado): carritos sin compra posterior en el período
SET @desde = '2026-05-01', @hasta = '2026-09-30';
SELECT ca.id_carrito, CONCAT(c.nombre, ' ', c.apellido) AS cliente, c.email, ca.fecha_actualizacion,
       COUNT(i.id_item) AS productos_en_carrito, SUM(i.cantidad * p.precio) AS valor_carrito
FROM carritos ca
JOIN clientes c ON c.id_cliente = ca.id_cliente
JOIN carrito_items i ON i.id_carrito = ca.id_carrito
JOIN productos p ON p.id_producto = i.id_producto
WHERE ca.estado <> 'Convertido'
  AND ca.fecha_actualizacion BETWEEN @desde AND @hasta
  AND NOT EXISTS (SELECT 1 FROM ventas v
                  WHERE v.id_cliente = ca.id_cliente AND v.fecha_venta >= ca.fecha_creacion AND v.estado <> 'Cancelado')
GROUP BY ca.id_carrito, c.nombre, c.apellido, c.email, ca.fecha_actualizacion
ORDER BY valor_carrito DESC;

-- 11. Rendimiento de Proveedores: ranking por volumen de ventas de sus productos
SELECT RANK() OVER (ORDER BY SUM(d.cantidad * d.precio_unitario_congelado) DESC) AS ranking,
       pr.nombre AS proveedor, SUM(d.cantidad) AS unidades, SUM(d.cantidad * d.precio_unitario_congelado) AS ingresos
FROM proveedores pr
JOIN productos p ON p.id_proveedor = pr.id_proveedor
JOIN detalle_ventas d ON d.id_producto = p.id_producto
JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
GROUP BY pr.id_proveedor, pr.nombre
ORDER BY ranking;

-- 12. Análisis Geográfico de Ventas (por región y ciudad del cliente)
SELECT c.region, c.ciudad, COUNT(DISTINCT c.id_cliente) AS clientes, COUNT(v.id_venta) AS ventas, SUM(v.total) AS total_ventas
FROM ventas v
JOIN clientes c ON c.id_cliente = v.id_cliente
WHERE v.estado <> 'Cancelado'
GROUP BY c.region, c.ciudad
ORDER BY total_ventas DESC;

-- 13. Ventas por Hora del Día (horas pico de compra)
SELECT HOUR(fecha_venta) AS hora, COUNT(*) AS num_ventas, SUM(total) AS total_ventas,
       RANK() OVER (ORDER BY COUNT(*) DESC) AS ranking_hora
FROM ventas
WHERE estado <> 'Cancelado'
GROUP BY HOUR(fecha_venta)
ORDER BY hora;

-- 14. Impacto de Promociones: unidades antes / durante / después (ventanas de igual duración)
SELECT pm.codigo, pr.nombre AS producto, pm.porcentaje_descuento AS pct_desc,
       SUM(CASE WHEN v.fecha_venta >= pm.fecha_inicio - INTERVAL (DATEDIFF(pm.fecha_fin, pm.fecha_inicio) + 1) DAY
                 AND v.fecha_venta <  pm.fecha_inicio THEN d.cantidad ELSE 0 END) AS unidades_antes,
       SUM(CASE WHEN v.fecha_venta >= pm.fecha_inicio AND v.fecha_venta <= pm.fecha_fin THEN d.cantidad ELSE 0 END) AS unidades_durante,
       SUM(CASE WHEN v.fecha_venta >  pm.fecha_fin
                 AND v.fecha_venta <= pm.fecha_fin + INTERVAL (DATEDIFF(pm.fecha_fin, pm.fecha_inicio) + 1) DAY THEN d.cantidad ELSE 0 END) AS unidades_despues
FROM promociones pm
JOIN productos pr ON pr.id_producto = pm.id_producto
LEFT JOIN detalle_ventas d ON d.id_producto = pm.id_producto
LEFT JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
GROUP BY pm.id_promocion, pm.codigo, pr.nombre, pm.porcentaje_descuento, pm.fecha_inicio, pm.fecha_fin
ORDER BY pm.fecha_inicio;

-- 15. Análisis de Cohortes: retención mensual desde la primera compra
WITH primera AS (
  SELECT id_cliente, DATE_FORMAT(MIN(fecha_venta), '%Y-%m-01') AS cohorte
  FROM ventas WHERE estado <> 'Cancelado' GROUP BY id_cliente
), actividad AS (
  SELECT DISTINCT id_cliente, DATE_FORMAT(fecha_venta, '%Y-%m-01') AS mes
  FROM ventas WHERE estado <> 'Cancelado'
), tam AS (
  SELECT cohorte, COUNT(*) AS clientes_cohorte FROM primera GROUP BY cohorte
)
SELECT DATE_FORMAT(p.cohorte, '%Y-%m') AS cohorte, t.clientes_cohorte,
       TIMESTAMPDIFF(MONTH, p.cohorte, a.mes) AS meses_desde_primera_compra,
       COUNT(DISTINCT a.id_cliente) AS clientes_activos,
       ROUND(100 * COUNT(DISTINCT a.id_cliente) / t.clientes_cohorte, 1) AS retencion_pct
FROM primera p
JOIN actividad a ON a.id_cliente = p.id_cliente AND a.mes >= p.cohorte
JOIN tam t ON t.cohorte = p.cohorte
GROUP BY p.cohorte, t.clientes_cohorte, TIMESTAMPDIFF(MONTH, p.cohorte, a.mes)
ORDER BY p.cohorte, meses_desde_primera_compra;

-- 16. Margen de Beneficio por Producto (margen unitario y margen realizado)
SELECT p.id_producto, p.nombre, p.precio, p.costo,
       ROUND(p.precio - p.costo, 2) AS margen_unitario,
       ROUND(100 * (p.precio - p.costo) / p.precio, 2) AS margen_pct,
       COALESCE(SUM(d.cantidad * (d.precio_unitario_congelado - p.costo)), 0) AS utilidad_realizada
FROM productos p
LEFT JOIN detalle_ventas d ON d.id_producto = p.id_producto
LEFT JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
GROUP BY p.id_producto, p.nombre, p.precio, p.costo
ORDER BY margen_pct DESC;

-- 17. Tiempo Promedio Entre Compras (por cliente y global, en días)
WITH gaps AS (
  SELECT id_cliente, fecha_venta,
         DATEDIFF(fecha_venta, LAG(fecha_venta) OVER (PARTITION BY id_cliente ORDER BY fecha_venta)) AS dias_desde_anterior
  FROM ventas WHERE estado <> 'Cancelado'
)
SELECT id_cliente, COUNT(dias_desde_anterior) AS intervalos, ROUND(AVG(dias_desde_anterior), 1) AS dias_promedio,
       (SELECT ROUND(AVG(dias_desde_anterior), 1) FROM gaps) AS promedio_global
FROM gaps
GROUP BY id_cliente
HAVING intervalos > 0
ORDER BY dias_promedio;

-- 18. Productos Más Vistos vs. Comprados (tasa de conversión)
SELECT p.nombre, COALESCE(vi.visitas, 0) AS visitas, COALESCE(co.unidades, 0) AS unidades_compradas,
       ROUND(100 * COALESCE(co.unidades, 0) / NULLIF(vi.visitas, 0), 2) AS conversion_pct,
       RANK() OVER (ORDER BY COALESCE(vi.visitas, 0) DESC)  AS rank_visitas,
       RANK() OVER (ORDER BY COALESCE(co.unidades, 0) DESC) AS rank_compras
FROM productos p
LEFT JOIN (SELECT id_producto, COUNT(*) AS visitas FROM visitas_producto GROUP BY id_producto) vi ON vi.id_producto = p.id_producto
LEFT JOIN (SELECT d.id_producto, SUM(d.cantidad) AS unidades
           FROM detalle_ventas d JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
           GROUP BY d.id_producto) co ON co.id_producto = p.id_producto
ORDER BY visitas DESC;

-- 19. Segmentación de Clientes (RFM): quintiles de Recencia, Frecuencia y Valor Monetario
WITH base AS (
  SELECT id_cliente, DATEDIFF(CURDATE(), MAX(fecha_venta)) AS recencia_dias,
         COUNT(*) AS frecuencia, SUM(total) AS monetario
  FROM ventas WHERE estado <> 'Cancelado' GROUP BY id_cliente
), puntajes AS (
  SELECT *, NTILE(5) OVER (ORDER BY recencia_dias DESC) AS r,
            NTILE(5) OVER (ORDER BY frecuencia ASC)     AS f,
            NTILE(5) OVER (ORDER BY monetario ASC)      AS m
  FROM base
)
SELECT id_cliente, recencia_dias, frecuencia, monetario, r, f, m,
       CASE WHEN r >= 4 AND f >= 4 AND m >= 4 THEN 'Campeón'
            WHEN r >= 3 AND f >= 3 THEN 'Leal'
            WHEN r >= 4 AND f <= 2 THEN 'Nuevo / Prometedor'
            WHEN r <= 2 AND f >= 3 THEN 'En riesgo'
            WHEN r <= 2 AND f <= 2 THEN 'Perdido'
            ELSE 'Ocasional' END AS segmento
FROM puntajes
ORDER BY r DESC, f DESC, m DESC;

-- 20. Predicción de Demanda Simple: ventas del próximo mes de una categoría
--     (promedio móvil de 3 meses y regresión lineal sobre los últimos 6 meses completos)
SET @categoria = 'Electrónica';
WITH mensual AS (
  SELECT DATE_FORMAT(v.fecha_venta, '%Y-%m') AS mes, SUM(d.cantidad * d.precio_unitario_congelado) AS ventas
  FROM detalle_ventas d
  JOIN ventas v ON v.id_venta = d.id_venta AND v.estado <> 'Cancelado'
  JOIN productos p ON p.id_producto = d.id_producto
  JOIN categorias c ON c.id_categoria = p.id_categoria
  WHERE c.nombre = @categoria
    AND v.fecha_venta <  DATE_FORMAT(CURDATE(), '%Y-%m-01')
    AND v.fecha_venta >= DATE_SUB(DATE_FORMAT(CURDATE(), '%Y-%m-01'), INTERVAL 6 MONTH)
  GROUP BY DATE_FORMAT(v.fecha_venta, '%Y-%m')
), num AS (
  SELECT mes, ventas, ROW_NUMBER() OVER (ORDER BY mes) AS x FROM mensual
), reg AS (
  SELECT COUNT(*) AS n, SUM(x) AS sx, SUM(ventas) AS sy, SUM(x * ventas) AS sxy, SUM(x * x) AS sxx FROM num
)
SELECT @categoria AS categoria, n AS meses_usados,
       ROUND((SELECT AVG(ventas) FROM (SELECT ventas FROM num ORDER BY x DESC LIMIT 3) u), 2) AS proyeccion_promedio_movil,
       ROUND(((sy - ((n * sxy - sx * sy) / NULLIF(n * sxx - sx * sx, 0)) * sx) / n)
             + ((n * sxy - sx * sy) / NULLIF(n * sxx - sx * sx, 0)) * (n + 1), 2) AS proyeccion_regresion_lineal
FROM reg;
