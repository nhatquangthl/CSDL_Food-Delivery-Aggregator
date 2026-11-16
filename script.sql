SET client_encoding = 'UTF8';
-- Kích hoạt phần mở rộng PostGIS để xử lý kiểu dữ liệu GEOMETRY(Point, 4326)
CREATE EXTENSION IF NOT EXISTS postgis;

-- Khởi tạo các kiểu dữ liệu liệt kê (ENUM) theo đúng Từ điển dữ liệu
CREATE TYPE user_role_enum AS ENUM ('CUSTOMER', 'DRIVER', 'RESTAURANT_OWNER');
CREATE TYPE stock_status_enum AS ENUM ('AVAILABLE', 'OUT_OF_STOCK');
CREATE TYPE order_status_enum AS ENUM (
    'PENDING', 'CONFIRMED', 'PREPARING', 'READY', 'PICKED_UP', 'DELIVERED', 'CANCELLED'
);

-- 1. Bảng USER (Superclass)
CREATE TABLE "USER" (
    user_id VARCHAR(10) PRIMARY KEY,
    user_type user_role_enum NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    phone_number VARCHAR(15) UNIQUE NOT NULL,
    password_hash VARCHAR(256) NOT NULL,
    CONSTRAINT chk_user_id_prefix CHECK (user_id ~ '^USR[0-9]{7}$')
);

-- 2. Bảng CUSTOMER (Subclass)
CREATE TABLE CUSTOMER (
    user_id VARCHAR(10) PRIMARY KEY REFERENCES "USER"(user_id) ON DELETE CASCADE,
    default_delivery_address VARCHAR(255) NULL,
    payment_token VARCHAR(255) NULL
);

-- 3. Bảng DRIVER (Subclass)
CREATE TABLE DRIVER (
    user_id VARCHAR(10) PRIMARY KEY REFERENCES "USER"(user_id) ON DELETE CASCADE,
    license_plate VARCHAR(20) UNIQUE NOT NULL,
    is_active_order BOOLEAN NOT NULL DEFAULT FALSE,
    location GEOMETRY(Point, 4326) NULL,
    CONSTRAINT chk_driver_coords CHECK (
        location IS NULL OR (
            ST_Y(location) BETWEEN -90 AND 90 AND
            ST_X(location) BETWEEN -180 AND 180
        )
    )
);

-- 4. Bảng RESTAURANT_OWNER (Subclass)
CREATE TABLE RESTAURANT_OWNER (
    user_id VARCHAR(10) PRIMARY KEY REFERENCES "USER"(user_id) ON DELETE CASCADE,
    tax_id VARCHAR(15) UNIQUE NOT NULL
);

-- 5. Bảng RESTAURANT
CREATE TABLE RESTAURANT (
    restaurant_id VARCHAR(10) PRIMARY KEY,
    owner_id VARCHAR(10) NOT NULL REFERENCES RESTAURANT_OWNER(user_id),
    restaurant_name VARCHAR(100) NOT NULL,
    address VARCHAR(255) NOT NULL,
    location GEOMETRY(Point, 4326) NOT NULL,
    CONSTRAINT chk_res_id_prefix CHECK (restaurant_id ~ '^RES[0-9]{7}$'),
    CONSTRAINT chk_res_coords CHECK (
        ST_Y(location) BETWEEN -90 AND 90 AND
        ST_X(location) BETWEEN -180 AND 180
    )
);

-- 6. Bảng MENU_ITEM
CREATE TABLE MENU_ITEM (
    item_id VARCHAR(10) PRIMARY KEY,
    restaurant_id VARCHAR(10) NOT NULL REFERENCES RESTAURANT(restaurant_id),
    item_name VARCHAR(255) NOT NULL CHECK (LENGTH(TRIM(item_name)) > 0),
    current_price INT NOT NULL DEFAULT 0 CHECK (current_price >= 0),
    stock_status stock_status_enum NOT NULL DEFAULT 'AVAILABLE',
    CONSTRAINT chk_itm_id_prefix CHECK (item_id ~ '^ITM[0-9]{7}$')
);

-- 7. Bảng ORDER
CREATE TABLE "ORDER" (
    order_id VARCHAR(10) PRIMARY KEY,
    customer_id VARCHAR(10) NOT NULL REFERENCES CUSTOMER(user_id),
    restaurant_id VARCHAR(10) NOT NULL REFERENCES RESTAURANT(restaurant_id),
    driver_id VARCHAR(10) NULL REFERENCES DRIVER(user_id),
    order_status order_status_enum NOT NULL DEFAULT 'PENDING',
    shipping_fee INT NOT NULL DEFAULT 0 CHECK (shipping_fee >= 0),
    total_amount INT NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    placed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    picked_up_at TIMESTAMP NULL,
    delivered_at TIMESTAMP NULL,
    delivery_address VARCHAR(255) NOT NULL,
    CONSTRAINT chk_ord_id_prefix CHECK (order_id ~ '^ORD[0-9]{7}$'),
    CONSTRAINT chk_temporal_integrity CHECK (
        (picked_up_at IS NULL OR picked_up_at > placed_at) AND
        (delivered_at IS NULL OR (picked_up_at IS NOT NULL AND delivered_at > picked_up_at))
    )
);

-- 8. Bảng ORDER_ITEM
CREATE TABLE ORDER_ITEM (
    order_id VARCHAR(10) NOT NULL REFERENCES "ORDER"(order_id) ON DELETE CASCADE,
    item_id VARCHAR(10) NOT NULL REFERENCES MENU_ITEM(item_id),
    quantity INT NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_price INT NOT NULL CHECK (unit_price >= 0),
    PRIMARY KEY (order_id, item_id)
);

-- Tạo chỉ mục không gian GIST để đảm bảo NFR truy vấn bán kính < 200ms
CREATE INDEX idx_driver_location_gist ON DRIVER USING GIST (location);
CREATE INDEX idx_restaurant_location_gist ON RESTAURANT USING GIST (location);

-- TRIGGER 1: Kiểm soát máy trạng thái đơn hàng (BR02) và đồng bộ trạng thái tài xế (BR04)
CREATE OR REPLACE FUNCTION fn_enforce_order_lifecycle()
RETURNS TRIGGER AS $$
DECLARE
    v_driver_busy BOOLEAN;
BEGIN
    -- Kiểm tra chuyển đổi trạng thái hợp lệ (BR02)
    IF OLD.order_status IS DISTINCT FROM NEW.order_status THEN
        IF OLD.order_status = 'PENDING' AND NEW.order_status NOT IN ('CONFIRMED', 'CANCELLED') THEN
            RAISE EXCEPTION 'Vi phạm BR02: Không thể chuyển trực tiếp từ PENDING sang %', NEW.order_status;
        ELSIF OLD.order_status = 'CONFIRMED' AND NEW.order_status NOT IN ('PREPARING', 'CANCELLED') THEN
            RAISE EXCEPTION 'Vi phạm BR02: Không thể chuyển trực tiếp từ CONFIRMED sang %', NEW.order_status;
        ELSIF OLD.order_status = 'PREPARING' AND NEW.order_status = 'CANCELLED' THEN
            RAISE EXCEPTION 'Vi phạm BR02: Nhà hàng đã chuyển sang PREPARING, không cho phép hủy đơn (CANCELLED)';
        ELSIF OLD.order_status = 'PREPARING' AND NEW.order_status <> 'READY' THEN
            RAISE EXCEPTION 'Vi phạm BR02: Từ PREPARING bắt buộc chuyển sang READY';
        ELSIF OLD.order_status = 'READY' AND NEW.order_status <> 'PICKED_UP' THEN
            RAISE EXCEPTION 'Vi phạm BR02: Từ READY bắt buộc chuyển sang PICKED_UP';
        ELSIF OLD.order_status = 'PICKED_UP' AND NEW.order_status <> 'DELIVERED' THEN
            RAISE EXCEPTION 'Vi phạm BR02: Từ PICKED_UP bắt buộc chuyển sang DELIVERED';
        ELSIF OLD.order_status IN ('DELIVERED', 'CANCELLED') THEN
            RAISE EXCEPTION 'Vi phạm BR02: Đơn hàng đã kết thúc ở trạng thái %, không thể cập nhật', OLD.order_status;
        END IF;
    END IF;

    -- Khi gán tài xế mới vào đơn hàng: Kiểm tra tài xế phải đang rảnh (BR04)
    IF OLD.driver_id IS NULL AND NEW.driver_id IS NOT NULL THEN
        SELECT is_active_order INTO v_driver_busy FROM DRIVER WHERE user_id = NEW.driver_id FOR UPDATE;
        IF v_driver_busy = TRUE THEN
            RAISE EXCEPTION 'Vi phạm BR04: Tài xế % đang thực hiện đơn hàng khác (is_active_order = TRUE)', NEW.driver_id;
        END IF;
        UPDATE DRIVER SET is_active_order = TRUE WHERE user_id = NEW.driver_id;
    END IF;

    -- Tự động ghi nhận mốc thời gian và giải phóng tài xế khi giao tất
    IF NEW.order_status = 'PICKED_UP' AND OLD.order_status <> 'PICKED_UP' THEN
        NEW.picked_up_at := COALESCE(NEW.picked_up_at, CURRENT_TIMESTAMP);
    ELSIF NEW.order_status = 'DELIVERED' AND OLD.order_status <> 'DELIVERED' THEN
        NEW.delivered_at := COALESCE(NEW.delivered_at, CURRENT_TIMESTAMP);
        IF NEW.driver_id IS NOT NULL THEN
            UPDATE DRIVER SET is_active_order = FALSE WHERE user_id = NEW.driver_id;
        END IF;
    ELSIF NEW.order_status = 'CANCELLED' AND NEW.driver_id IS NOT NULL THEN
        UPDATE DRIVER SET is_active_order = FALSE WHERE user_id = NEW.driver_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_lifecycle
BEFORE UPDATE ON "ORDER"
FOR EACH ROW EXECUTE FUNCTION fn_enforce_order_lifecycle();

-- TRIGGER 2: Tự động Snapshot đơn giá (BR03), kiểm tra tồn kho (SC) và cập nhật tổng tiền
CREATE OR REPLACE FUNCTION fn_snapshot_item_price_and_total()
RETURNS TRIGGER AS $$
DECLARE
    v_price INT;
    v_stock stock_status_enum;
BEGIN
    SELECT current_price, stock_status INTO v_price, v_stock
    FROM MENU_ITEM WHERE item_id = NEW.item_id;

    IF v_stock = 'OUT_OF_STOCK' THEN
        RAISE EXCEPTION 'Vi phạm SC: Món ăn % hiện đang hết hàng (OUT_OF_STOCK)', NEW.item_id;
    END IF;

    -- Tự động chép giá niêm yết tại thời điểm đặt vào unit_price (BR03 Snapshot)
    NEW.unit_price := v_price;

    -- Cập nhật lại total_amount của bảng ORDER
    UPDATE "ORDER"
    SET total_amount = shipping_fee + COALESCE((
        SELECT SUM(quantity * unit_price) FROM ORDER_ITEM WHERE order_id = NEW.order_id
    ), 0) + (NEW.quantity * NEW.unit_price)
    WHERE order_id = NEW.order_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_order_item_snapshot
BEFORE INSERT ON ORDER_ITEM
FOR EACH ROW EXECUTE FUNCTION fn_snapshot_item_price_and_total();

-- Chèn dữ liệu mẫu (Mock DML) phục vụ Demo trực tiếp
INSERT INTO "USER" VALUES
('USR0000001', 'CUSTOMER', 'Thân Lê Nhật Quang', '0901000001', 'sha256_hash_quang_01'),
('USR0000002', 'RESTAURANT_OWNER', 'Nguyễn Tấn Tài', '0901000002', 'sha256_hash_tai_02'),
('USR0000003', 'DRIVER', 'Trần Thiên Hoàng Quân', '0901000003', 'sha256_hash_quan_03'),
('USR0000004', 'DRIVER', 'Lê Hoàng Nam', '0901000004', 'sha256_hash_nam_04');

INSERT INTO CUSTOMER VALUES
('USR0000001', '97 Man Thiện, Phường Hiệp Phú, TP. Thủ Đức, TP.HCM', 'tok_visa_ptit_99');

INSERT INTO RESTAURANT_OWNER VALUES
('USR0000002', '0312345678');

-- Tọa độ chuẩn WGS 84: ST_SetSRID(ST_MakePoint(Kinh_độ, Vĩ_độ), 4326)
INSERT INTO DRIVER VALUES
('USR0000003', '59X3-888.99', FALSE, ST_SetSRID(ST_MakePoint(106.7865, 10.8478), 4326)),
('USR0000004', '59X1-123.45', TRUE,  ST_SetSRID(ST_MakePoint(106.7870, 10.8482), 4326));

INSERT INTO RESTAURANT VALUES
('RES0000001', 'USR0000002', 'Cơm Tấm Sài Gòn F&F', '11 Nguyễn Đình Chiểu, Quận 1, TP.HCM',
 ST_SetSRID(ST_MakePoint(106.7850, 10.8470), 4326));

INSERT INTO MENU_ITEM VALUES
('ITM0000001', 'RES0000001', 'Cơm Sườn Bì Chả Đặc Biệt', 55000, 'AVAILABLE'),
('ITM0000002', 'RES0000001', 'Trà Đào Cam Sả', 25000, 'AVAILABLE'),
('ITM0000003', 'RES0000001', 'Canh Khổ Qua Nhồi Thịt', 20000, 'OUT_OF_STOCK');