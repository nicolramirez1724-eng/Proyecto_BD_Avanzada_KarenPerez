-- =====================================================================
-- 03_Funciones.sql
-- 20 funciones definidas por el usuario (UDF) - MySQL 8.0
-- Nota: los nombres se escriben en ASCII (sin "ñ") para evitar problemas de codificación.
-- =====================================================================
USE ecommerce_db;
DELIMITER $$

-- 1. Total de una venta (suma de cantidad * precio congelado)
DROP FUNCTION IF EXISTS fn_CalcularTotalVenta$$
CREATE FUNCTION fn_CalcularTotalVenta(p_id_venta INT) RETURNS DECIMAL(14,2)
READS SQL DATA
BEGIN
  DECLARE v_total DECIMAL(14,2);
  SELECT COALESCE(SUM(cantidad * precio_unitario_congelado), 0) INTO v_total
  FROM detalle_ventas WHERE id_venta = p_id_venta;
  RETURN v_total;
END$$

-- 2. Disponibilidad de stock (1 = hay stock suficiente y el producto está activo)
DROP FUNCTION IF EXISTS fn_VerificarDisponibilidadStock$$
CREATE FUNCTION fn_VerificarDisponibilidadStock(p_id_producto INT, p_cantidad INT) RETURNS TINYINT(1)
READS SQL DATA
BEGIN
  DECLARE v_ok TINYINT(1) DEFAULT 0;
  SELECT (stock >= p_cantidad AND activo = 1) INTO v_ok FROM productos WHERE id_producto = p_id_producto;
  RETURN COALESCE(v_ok, 0);
END$$

-- 3. Precio actual de un producto
DROP FUNCTION IF EXISTS fn_ObtenerPrecioProducto$$
CREATE FUNCTION fn_ObtenerPrecioProducto(p_id_producto INT) RETURNS DECIMAL(12,2)
READS SQL DATA
BEGIN
  DECLARE v_precio DECIMAL(12,2);
  SELECT precio INTO v_precio FROM productos WHERE id_producto = p_id_producto;
  RETURN v_precio;
END$$

-- 4. Edad del cliente a partir de su fecha de nacimiento
DROP FUNCTION IF EXISTS fn_CalcularEdadCliente$$
CREATE FUNCTION fn_CalcularEdadCliente(p_id_cliente INT) RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_nac DATE;
  SELECT fecha_nacimiento INTO v_nac FROM clientes WHERE id_cliente = p_id_cliente;
  RETURN TIMESTAMPDIFF(YEAR, v_nac, CURDATE());   -- NULL si no hay fecha
END$$

-- 5. Nombre completo estandarizado: "APELLIDO, Nombre"
DROP FUNCTION IF EXISTS fn_FormatearNombreCompleto$$
CREATE FUNCTION fn_FormatearNombreCompleto(p_id_cliente INT) RETURNS VARCHAR(170)
READS SQL DATA
BEGIN
  DECLARE v_res VARCHAR(170);
  SELECT CONCAT(UPPER(TRIM(apellido)), ', ', TRIM(nombre)) INTO v_res FROM clientes WHERE id_cliente = p_id_cliente;
  RETURN v_res;
END$$

-- 6. ¿Cliente nuevo? (primera compra en los últimos 30 días)
DROP FUNCTION IF EXISTS fn_EsClienteNuevo$$
CREATE FUNCTION fn_EsClienteNuevo(p_id_cliente INT) RETURNS TINYINT(1)
READS SQL DATA
BEGIN
  DECLARE v_primera DATETIME;
  SELECT MIN(fecha_venta) INTO v_primera FROM ventas WHERE id_cliente = p_id_cliente AND estado <> 'Cancelado';
  RETURN (v_primera IS NOT NULL AND v_primera >= DATE_SUB(NOW(), INTERVAL 30 DAY));
END$$

-- 7. Costo de envío según el peso total de la venta: 5.00 hasta 1 kg + 1.50 por kg adicional (redondeado hacia arriba)
DROP FUNCTION IF EXISTS fn_CalcularCostoEnvio$$
CREATE FUNCTION fn_CalcularCostoEnvio(p_id_venta INT) RETURNS DECIMAL(10,2)
READS SQL DATA
BEGIN
  DECLARE v_peso DECIMAL(12,3);
  SELECT COALESCE(SUM(d.cantidad * p.peso_kg), 0) INTO v_peso
  FROM detalle_ventas d JOIN productos p ON p.id_producto = d.id_producto
  WHERE d.id_venta = p_id_venta;
  IF v_peso <= 0 THEN RETURN 0; END IF;
  RETURN 5.00 + GREATEST(CEIL(v_peso) - 1, 0) * 1.50;
END$$

-- 8. Aplicar un porcentaje de descuento a un monto
DROP FUNCTION IF EXISTS fn_AplicarDescuento$$
CREATE FUNCTION fn_AplicarDescuento(p_monto DECIMAL(14,2), p_porcentaje DECIMAL(5,2)) RETURNS DECIMAL(14,2)
DETERMINISTIC
BEGIN
  IF p_porcentaje < 0 OR p_porcentaje > 100 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'El porcentaje de descuento debe estar entre 0 y 100';
  END IF;
  RETURN ROUND(p_monto * (1 - p_porcentaje / 100), 2);
END$$

-- 9. Fecha de la última compra de un cliente
DROP FUNCTION IF EXISTS fn_ObtenerUltimaFechaCompra$$
CREATE FUNCTION fn_ObtenerUltimaFechaCompra(p_id_cliente INT) RETURNS DATETIME
READS SQL DATA
BEGIN
  DECLARE v_fecha DATETIME;
  SELECT MAX(fecha_venta) INTO v_fecha FROM ventas WHERE id_cliente = p_id_cliente AND estado <> 'Cancelado';
  RETURN v_fecha;
END$$

-- 10. Validar formato de correo electrónico
DROP FUNCTION IF EXISTS fn_ValidarFormatoEmail$$
CREATE FUNCTION fn_ValidarFormatoEmail(p_email VARCHAR(255)) RETURNS TINYINT(1)
DETERMINISTIC
BEGIN
  RETURN COALESCE(p_email REGEXP '^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+([.][A-Za-z0-9-]+)*[.][A-Za-z]{2,}$', 0);
END$$

-- 11. Nombre de la categoría de un producto
DROP FUNCTION IF EXISTS fn_ObtenerNombreCategoria$$
CREATE FUNCTION fn_ObtenerNombreCategoria(p_id_producto INT) RETURNS VARCHAR(80)
READS SQL DATA
BEGIN
  DECLARE v_nombre VARCHAR(80);
  SELECT c.nombre INTO v_nombre
  FROM productos p JOIN categorias c ON c.id_categoria = p.id_categoria
  WHERE p.id_producto = p_id_producto;
  RETURN v_nombre;
END$$

-- 12. Número de compras (no canceladas) de un cliente
DROP FUNCTION IF EXISTS fn_ContarVentasCliente$$
CREATE FUNCTION fn_ContarVentasCliente(p_id_cliente INT) RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_n INT;
  SELECT COUNT(*) INTO v_n FROM ventas WHERE id_cliente = p_id_cliente AND estado <> 'Cancelado';
  RETURN v_n;
END$$

-- 13. Días transcurridos desde la última compra (NULL si nunca compró)
DROP FUNCTION IF EXISTS fn_CalcularDiasDesdeUltimaCompra$$
CREATE FUNCTION fn_CalcularDiasDesdeUltimaCompra(p_id_cliente INT) RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_fecha DATETIME;
  SET v_fecha = fn_ObtenerUltimaFechaCompra(p_id_cliente);
  RETURN DATEDIFF(CURDATE(), DATE(v_fecha));
END$$

-- 14. Estado de lealtad según gasto total: Oro >= 3000, Plata >= 1000, Bronce en otro caso
DROP FUNCTION IF EXISTS fn_DeterminarEstadoLealtad$$
CREATE FUNCTION fn_DeterminarEstadoLealtad(p_id_cliente INT) RETURNS VARCHAR(10)
READS SQL DATA
BEGIN
  DECLARE v_gasto DECIMAL(14,2);
  SELECT COALESCE(SUM(total), 0) INTO v_gasto FROM ventas WHERE id_cliente = p_id_cliente AND estado <> 'Cancelado';
  RETURN CASE WHEN v_gasto >= 3000 THEN 'Oro' WHEN v_gasto >= 1000 THEN 'Plata' ELSE 'Bronce' END;
END$$

-- 15. Generar SKU: CAT-NOMB-0001 (prefijo de categoría, 4 letras del nombre, consecutivo)
DROP FUNCTION IF EXISTS fn_GenerarSKU$$
CREATE FUNCTION fn_GenerarSKU(p_nombre VARCHAR(150), p_id_categoria INT) RETURNS VARCHAR(40)
READS SQL DATA
BEGIN
  DECLARE v_cat VARCHAR(80);
  DECLARE v_sig INT;
  DECLARE v_sku VARCHAR(40);
  SELECT nombre INTO v_cat FROM categorias WHERE id_categoria = p_id_categoria;
  SELECT COALESCE(MAX(id_producto), 0) + 1 INTO v_sig FROM productos;
  SET v_sku = CONCAT(UPPER(LEFT(COALESCE(v_cat, 'GEN'), 3)), '-',
                     UPPER(LEFT(REGEXP_REPLACE(p_nombre, '[^A-Za-z0-9]', ''), 4)), '-', LPAD(v_sig, 4, '0'));
  WHILE EXISTS (SELECT 1 FROM productos WHERE sku = v_sku) DO      -- garantiza unicidad
    SET v_sig = v_sig + 1;
    SET v_sku = CONCAT(UPPER(LEFT(COALESCE(v_cat, 'GEN'), 3)), '-',
                       UPPER(LEFT(REGEXP_REPLACE(p_nombre, '[^A-Za-z0-9]', ''), 4)), '-', LPAD(v_sig, 4, '0'));
  END WHILE;
  RETURN v_sku;
END$$

-- 16. IVA (19 %) sobre el total de una venta
DROP FUNCTION IF EXISTS fn_CalcularIVA$$
CREATE FUNCTION fn_CalcularIVA(p_id_venta INT) RETURNS DECIMAL(14,2)
READS SQL DATA
BEGIN
  RETURN ROUND(fn_CalcularTotalVenta(p_id_venta) * 0.19, 2);
END$$

-- 17. Stock total de una categoría
DROP FUNCTION IF EXISTS fn_ObtenerStockTotalPorCategoria$$
CREATE FUNCTION fn_ObtenerStockTotalPorCategoria(p_id_categoria INT) RETURNS INT
READS SQL DATA
BEGIN
  DECLARE v_stock INT;
  SELECT COALESCE(SUM(stock), 0) INTO v_stock FROM productos WHERE id_categoria = p_id_categoria;
  RETURN v_stock;
END$$

-- 18. Fecha estimada de entrega: 2 días si el cliente está en la ciudad de la sucursal, 5 días en otro caso
DROP FUNCTION IF EXISTS fn_EstimarFechaEntrega$$
CREATE FUNCTION fn_EstimarFechaEntrega(p_id_venta INT) RETURNS DATE
READS SQL DATA
BEGIN
  DECLARE v_fecha DATETIME;
  DECLARE v_ciudad_cli VARCHAR(80);
  DECLARE v_ciudad_suc VARCHAR(80);
  SELECT v.fecha_venta, c.ciudad, s.ciudad INTO v_fecha, v_ciudad_cli, v_ciudad_suc
  FROM ventas v
  JOIN clientes c ON c.id_cliente = v.id_cliente
  JOIN sucursales s ON s.id_sucursal = v.id_sucursal
  WHERE v.id_venta = p_id_venta;
  IF v_fecha IS NULL THEN RETURN NULL; END IF;
  RETURN DATE_ADD(DATE(v_fecha), INTERVAL IF(v_ciudad_cli = v_ciudad_suc, 2, 5) DAY);
END$$

-- 19. Conversión de moneda con tasas fijas (base USD)
DROP FUNCTION IF EXISTS fn_ConvertirMoneda$$
CREATE FUNCTION fn_ConvertirMoneda(p_monto DECIMAL(14,2), p_moneda_origen CHAR(3), p_moneda_destino CHAR(3)) RETURNS DECIMAL(16,2)
DETERMINISTIC
BEGIN
  DECLARE v_o DECIMAL(12,4);
  DECLARE v_d DECIMAL(12,4);
  SET v_o = CASE UPPER(p_moneda_origen)  WHEN 'USD' THEN 1 WHEN 'EUR' THEN 0.92 WHEN 'COP' THEN 4000 WHEN 'MXN' THEN 17.5 ELSE NULL END;
  SET v_d = CASE UPPER(p_moneda_destino) WHEN 'USD' THEN 1 WHEN 'EUR' THEN 0.92 WHEN 'COP' THEN 4000 WHEN 'MXN' THEN 17.5 ELSE NULL END;
  IF v_o IS NULL OR v_d IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Moneda no soportada (USD, EUR, COP, MXN)';
  END IF;
  RETURN ROUND(p_monto / v_o * v_d, 2);
END$$

-- 20. Complejidad de contraseña: >= 8 caracteres, mayúscula, minúscula, número y carácter especial
DROP FUNCTION IF EXISTS fn_ValidarComplejidadContrasena$$
CREATE FUNCTION fn_ValidarComplejidadContrasena(p_password VARCHAR(255)) RETURNS TINYINT(1)
DETERMINISTIC
BEGIN
  IF p_password IS NULL OR CHAR_LENGTH(p_password) < 8 THEN RETURN 0; END IF;
  RETURN REGEXP_LIKE(p_password, '[A-Z]', 'c')
     AND REGEXP_LIKE(p_password, '[a-z]', 'c')
     AND REGEXP_LIKE(p_password, '[0-9]')
     AND REGEXP_LIKE(p_password, '[^A-Za-z0-9]');
END$$

DELIMITER ;

-- Pruebas rápidas
-- SELECT fn_CalcularTotalVenta(1), fn_VerificarDisponibilidadStock(1, 2), fn_ValidarFormatoEmail('a@b.co'),
--        fn_ConvertirMoneda(100, 'USD', 'COP'), fn_ValidarComplejidadContrasena('Abcdef1!');
