--
-- PostgreSQL database dump
--

\restrict 0d4FgVgABYrECpz4daZYSLsZZEwfmgv47owfcVD4EFq5EqjgsbcvKHmlicdIZBQ

-- Dumped from database version 18.7
-- Dumped by pg_dump version 18.7

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: postgis; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;


--
-- Name: EXTENSION postgis; Type: COMMENT; Schema: -; Owner: 
--

COMMENT ON EXTENSION postgis IS 'PostGIS geometry and geography spatial types and functions';


--
-- Name: order_status_enum; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.order_status_enum AS ENUM (
    'PENDING',
    'CONFIRMED',
    'PREPARING',
    'READY',
    'PICKED_UP',
    'DELIVERED',
    'CANCELLED'
);


ALTER TYPE public.order_status_enum OWNER TO postgres;

--
-- Name: stock_status_enum; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.stock_status_enum AS ENUM (
    'AVAILABLE',
    'OUT_OF_STOCK'
);


ALTER TYPE public.stock_status_enum OWNER TO postgres;

--
-- Name: user_role_enum; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.user_role_enum AS ENUM (
    'CUSTOMER',
    'DRIVER',
    'RESTAURANT_OWNER'
);


ALTER TYPE public.user_role_enum OWNER TO postgres;

--
-- Name: fn_enforce_order_lifecycle(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_enforce_order_lifecycle() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.fn_enforce_order_lifecycle() OWNER TO postgres;

--
-- Name: fn_snapshot_item_price_and_total(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.fn_snapshot_item_price_and_total() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.fn_snapshot_item_price_and_total() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ORDER; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."ORDER" (
    order_id character varying(10) NOT NULL,
    customer_id character varying(10) NOT NULL,
    restaurant_id character varying(10) NOT NULL,
    driver_id character varying(10),
    order_status public.order_status_enum DEFAULT 'PENDING'::public.order_status_enum NOT NULL,
    shipping_fee integer DEFAULT 0 NOT NULL,
    total_amount integer DEFAULT 0 NOT NULL,
    placed_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    picked_up_at timestamp without time zone,
    delivered_at timestamp without time zone,
    delivery_address character varying(255) NOT NULL,
    CONSTRAINT "ORDER_shipping_fee_check" CHECK ((shipping_fee >= 0)),
    CONSTRAINT "ORDER_total_amount_check" CHECK ((total_amount >= 0)),
    CONSTRAINT chk_ord_id_prefix CHECK (((order_id)::text ~ '^ORD[0-9]{7}$'::text)),
    CONSTRAINT chk_temporal_integrity CHECK ((((picked_up_at IS NULL) OR (picked_up_at > placed_at)) AND ((delivered_at IS NULL) OR ((picked_up_at IS NOT NULL) AND (delivered_at > picked_up_at)))))
);


ALTER TABLE public."ORDER" OWNER TO postgres;

--
-- Name: USER; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public."USER" (
    user_id character varying(10) NOT NULL,
    user_type public.user_role_enum NOT NULL,
    full_name character varying(100) NOT NULL,
    phone_number character varying(15) NOT NULL,
    password_hash character varying(256) NOT NULL,
    CONSTRAINT chk_user_id_prefix CHECK (((user_id)::text ~ '^USR[0-9]{7}$'::text))
);


ALTER TABLE public."USER" OWNER TO postgres;

--
-- Name: customer; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customer (
    user_id character varying(10) NOT NULL,
    default_delivery_address character varying(255),
    payment_token character varying(255)
);


ALTER TABLE public.customer OWNER TO postgres;

--
-- Name: driver; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.driver (
    user_id character varying(10) NOT NULL,
    license_plate character varying(20) NOT NULL,
    is_active_order boolean DEFAULT false NOT NULL,
    location public.geometry(Point,4326),
    CONSTRAINT chk_driver_coords CHECK (((location IS NULL) OR (((public.st_y(location) >= ('-90'::integer)::double precision) AND (public.st_y(location) <= (90)::double precision)) AND ((public.st_x(location) >= ('-180'::integer)::double precision) AND (public.st_x(location) <= (180)::double precision)))))
);


ALTER TABLE public.driver OWNER TO postgres;

--
-- Name: menu_item; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.menu_item (
    item_id character varying(10) NOT NULL,
    restaurant_id character varying(10) NOT NULL,
    item_name character varying(255) NOT NULL,
    current_price integer DEFAULT 0 NOT NULL,
    stock_status public.stock_status_enum DEFAULT 'AVAILABLE'::public.stock_status_enum NOT NULL,
    CONSTRAINT chk_itm_id_prefix CHECK (((item_id)::text ~ '^ITM[0-9]{7}$'::text)),
    CONSTRAINT menu_item_current_price_check CHECK ((current_price >= 0)),
    CONSTRAINT menu_item_item_name_check CHECK ((length(TRIM(BOTH FROM item_name)) > 0))
);


ALTER TABLE public.menu_item OWNER TO postgres;

--
-- Name: order_item; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.order_item (
    order_id character varying(10) NOT NULL,
    item_id character varying(10) NOT NULL,
    quantity integer DEFAULT 1 NOT NULL,
    unit_price integer NOT NULL,
    CONSTRAINT order_item_quantity_check CHECK ((quantity > 0)),
    CONSTRAINT order_item_unit_price_check CHECK ((unit_price >= 0))
);


ALTER TABLE public.order_item OWNER TO postgres;

--
-- Name: restaurant; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.restaurant (
    restaurant_id character varying(10) NOT NULL,
    owner_id character varying(10) NOT NULL,
    restaurant_name character varying(100) NOT NULL,
    address character varying(255) NOT NULL,
    location public.geometry(Point,4326) NOT NULL,
    CONSTRAINT chk_res_coords CHECK ((((public.st_y(location) >= ('-90'::integer)::double precision) AND (public.st_y(location) <= (90)::double precision)) AND ((public.st_x(location) >= ('-180'::integer)::double precision) AND (public.st_x(location) <= (180)::double precision)))),
    CONSTRAINT chk_res_id_prefix CHECK (((restaurant_id)::text ~ '^RES[0-9]{7}$'::text))
);


ALTER TABLE public.restaurant OWNER TO postgres;

--
-- Name: restaurant_owner; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.restaurant_owner (
    user_id character varying(10) NOT NULL,
    tax_id character varying(15) NOT NULL
);


ALTER TABLE public.restaurant_owner OWNER TO postgres;

--
-- Data for Name: ORDER; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."ORDER" (order_id, customer_id, restaurant_id, driver_id, order_status, shipping_fee, total_amount, placed_at, picked_up_at, delivered_at, delivery_address) FROM stdin;
\.


--
-- Data for Name: USER; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public."USER" (user_id, user_type, full_name, phone_number, password_hash) FROM stdin;
USR0000001	CUSTOMER	Thân Lê Nhật Quang	0901000001	sha256_hash_quang_01
USR0000002	RESTAURANT_OWNER	Nguyễn Tấn Tài	0901000002	sha256_hash_tai_02
USR0000003	DRIVER	Trần Thiên Hoàng Quân	0901000003	sha256_hash_quan_03
USR0000004	DRIVER	Lê Hoàng Nam	0901000004	sha256_hash_nam_04
USR0000005	CUSTOMER	Khách hàng mẫu 5	0900000005	hash_password_default_123
USR0000006	CUSTOMER	Khách hàng mẫu 6	0900000006	hash_password_default_123
USR0000007	CUSTOMER	Khách hàng mẫu 7	0900000007	hash_password_default_123
USR0000008	CUSTOMER	Khách hàng mẫu 8	0900000008	hash_password_default_123
USR0000009	CUSTOMER	Khách hàng mẫu 9	0900000009	hash_password_default_123
USR0000010	CUSTOMER	Khách hàng mẫu 10	0900000010	hash_password_default_123
USR0000011	CUSTOMER	Khách hàng mẫu 11	0900000011	hash_password_default_123
USR0000012	CUSTOMER	Khách hàng mẫu 12	0900000012	hash_password_default_123
USR0000013	CUSTOMER	Khách hàng mẫu 13	0900000013	hash_password_default_123
USR0000014	CUSTOMER	Khách hàng mẫu 14	0900000014	hash_password_default_123
USR0000015	CUSTOMER	Khách hàng mẫu 15	0900000015	hash_password_default_123
USR0000016	CUSTOMER	Khách hàng mẫu 16	0900000016	hash_password_default_123
USR0000017	CUSTOMER	Khách hàng mẫu 17	0900000017	hash_password_default_123
USR0000018	CUSTOMER	Khách hàng mẫu 18	0900000018	hash_password_default_123
USR0000019	CUSTOMER	Khách hàng mẫu 19	0900000019	hash_password_default_123
USR0000020	CUSTOMER	Khách hàng mẫu 20	0900000020	hash_password_default_123
USR0000021	CUSTOMER	Khách hàng mẫu 21	0900000021	hash_password_default_123
USR0000022	CUSTOMER	Khách hàng mẫu 22	0900000022	hash_password_default_123
USR0000023	CUSTOMER	Khách hàng mẫu 23	0900000023	hash_password_default_123
USR0000024	CUSTOMER	Khách hàng mẫu 24	0900000024	hash_password_default_123
USR0000025	CUSTOMER	Khách hàng mẫu 25	0900000025	hash_password_default_123
USR0000026	CUSTOMER	Khách hàng mẫu 26	0900000026	hash_password_default_123
USR0000027	CUSTOMER	Khách hàng mẫu 27	0900000027	hash_password_default_123
USR0000028	CUSTOMER	Khách hàng mẫu 28	0900000028	hash_password_default_123
USR0000029	CUSTOMER	Khách hàng mẫu 29	0900000029	hash_password_default_123
USR0000030	CUSTOMER	Khách hàng mẫu 30	0900000030	hash_password_default_123
USR0000031	CUSTOMER	Khách hàng mẫu 31	0900000031	hash_password_default_123
USR0000032	CUSTOMER	Khách hàng mẫu 32	0900000032	hash_password_default_123
USR0000033	CUSTOMER	Khách hàng mẫu 33	0900000033	hash_password_default_123
USR0000034	CUSTOMER	Khách hàng mẫu 34	0900000034	hash_password_default_123
USR0000035	CUSTOMER	Khách hàng mẫu 35	0900000035	hash_password_default_123
USR0000036	CUSTOMER	Khách hàng mẫu 36	0900000036	hash_password_default_123
USR0000037	CUSTOMER	Khách hàng mẫu 37	0900000037	hash_password_default_123
USR0000038	CUSTOMER	Khách hàng mẫu 38	0900000038	hash_password_default_123
USR0000039	CUSTOMER	Khách hàng mẫu 39	0900000039	hash_password_default_123
USR0000040	CUSTOMER	Khách hàng mẫu 40	0900000040	hash_password_default_123
USR0000041	CUSTOMER	Khách hàng mẫu 41	0900000041	hash_password_default_123
USR0000042	CUSTOMER	Khách hàng mẫu 42	0900000042	hash_password_default_123
USR0000043	CUSTOMER	Khách hàng mẫu 43	0900000043	hash_password_default_123
USR0000044	CUSTOMER	Khách hàng mẫu 44	0900000044	hash_password_default_123
USR0000045	CUSTOMER	Khách hàng mẫu 45	0900000045	hash_password_default_123
USR0000046	CUSTOMER	Khách hàng mẫu 46	0900000046	hash_password_default_123
USR0000047	CUSTOMER	Khách hàng mẫu 47	0900000047	hash_password_default_123
USR0000048	CUSTOMER	Khách hàng mẫu 48	0900000048	hash_password_default_123
USR0000049	CUSTOMER	Khách hàng mẫu 49	0900000049	hash_password_default_123
USR0000050	CUSTOMER	Khách hàng mẫu 50	0900000050	hash_password_default_123
USR0000051	CUSTOMER	Khách hàng mẫu 51	0900000051	hash_password_default_123
USR0000052	CUSTOMER	Khách hàng mẫu 52	0900000052	hash_password_default_123
USR0000053	CUSTOMER	Khách hàng mẫu 53	0900000053	hash_password_default_123
USR0000054	CUSTOMER	Khách hàng mẫu 54	0900000054	hash_password_default_123
USR0000055	CUSTOMER	Khách hàng mẫu 55	0900000055	hash_password_default_123
USR0000056	CUSTOMER	Khách hàng mẫu 56	0900000056	hash_password_default_123
USR0000057	CUSTOMER	Khách hàng mẫu 57	0900000057	hash_password_default_123
USR0000058	CUSTOMER	Khách hàng mẫu 58	0900000058	hash_password_default_123
USR0000059	CUSTOMER	Khách hàng mẫu 59	0900000059	hash_password_default_123
USR0000060	CUSTOMER	Khách hàng mẫu 60	0900000060	hash_password_default_123
USR0000061	CUSTOMER	Khách hàng mẫu 61	0900000061	hash_password_default_123
USR0000062	CUSTOMER	Khách hàng mẫu 62	0900000062	hash_password_default_123
USR0000063	CUSTOMER	Khách hàng mẫu 63	0900000063	hash_password_default_123
USR0000064	CUSTOMER	Khách hàng mẫu 64	0900000064	hash_password_default_123
USR0000065	CUSTOMER	Khách hàng mẫu 65	0900000065	hash_password_default_123
USR0000066	CUSTOMER	Khách hàng mẫu 66	0900000066	hash_password_default_123
USR0000067	CUSTOMER	Khách hàng mẫu 67	0900000067	hash_password_default_123
USR0000068	CUSTOMER	Khách hàng mẫu 68	0900000068	hash_password_default_123
USR0000069	CUSTOMER	Khách hàng mẫu 69	0900000069	hash_password_default_123
USR0000070	CUSTOMER	Khách hàng mẫu 70	0900000070	hash_password_default_123
USR0000071	CUSTOMER	Khách hàng mẫu 71	0900000071	hash_password_default_123
USR0000072	CUSTOMER	Khách hàng mẫu 72	0900000072	hash_password_default_123
USR0000073	CUSTOMER	Khách hàng mẫu 73	0900000073	hash_password_default_123
USR0000074	CUSTOMER	Khách hàng mẫu 74	0900000074	hash_password_default_123
USR0000075	CUSTOMER	Khách hàng mẫu 75	0900000075	hash_password_default_123
USR0000601	DRIVER	Tài xế mẫu 1	0800000601	hash_driver_123
USR0000076	CUSTOMER	Khách hàng mẫu 76	0900000076	hash_password_default_123
USR0000077	CUSTOMER	Khách hàng mẫu 77	0900000077	hash_password_default_123
USR0000078	CUSTOMER	Khách hàng mẫu 78	0900000078	hash_password_default_123
USR0000079	CUSTOMER	Khách hàng mẫu 79	0900000079	hash_password_default_123
USR0000080	CUSTOMER	Khách hàng mẫu 80	0900000080	hash_password_default_123
USR0000081	CUSTOMER	Khách hàng mẫu 81	0900000081	hash_password_default_123
USR0000082	CUSTOMER	Khách hàng mẫu 82	0900000082	hash_password_default_123
USR0000083	CUSTOMER	Khách hàng mẫu 83	0900000083	hash_password_default_123
USR0000084	CUSTOMER	Khách hàng mẫu 84	0900000084	hash_password_default_123
USR0000085	CUSTOMER	Khách hàng mẫu 85	0900000085	hash_password_default_123
USR0000086	CUSTOMER	Khách hàng mẫu 86	0900000086	hash_password_default_123
USR0000087	CUSTOMER	Khách hàng mẫu 87	0900000087	hash_password_default_123
USR0000088	CUSTOMER	Khách hàng mẫu 88	0900000088	hash_password_default_123
USR0000089	CUSTOMER	Khách hàng mẫu 89	0900000089	hash_password_default_123
USR0000090	CUSTOMER	Khách hàng mẫu 90	0900000090	hash_password_default_123
USR0000091	CUSTOMER	Khách hàng mẫu 91	0900000091	hash_password_default_123
USR0000092	CUSTOMER	Khách hàng mẫu 92	0900000092	hash_password_default_123
USR0000093	CUSTOMER	Khách hàng mẫu 93	0900000093	hash_password_default_123
USR0000094	CUSTOMER	Khách hàng mẫu 94	0900000094	hash_password_default_123
USR0000095	CUSTOMER	Khách hàng mẫu 95	0900000095	hash_password_default_123
USR0000096	CUSTOMER	Khách hàng mẫu 96	0900000096	hash_password_default_123
USR0000097	CUSTOMER	Khách hàng mẫu 97	0900000097	hash_password_default_123
USR0000098	CUSTOMER	Khách hàng mẫu 98	0900000098	hash_password_default_123
USR0000099	CUSTOMER	Khách hàng mẫu 99	0900000099	hash_password_default_123
USR0000100	CUSTOMER	Khách hàng mẫu 100	0900000100	hash_password_default_123
USR0000101	CUSTOMER	Khách hàng mẫu 101	0900000101	hash_password_default_123
USR0000102	CUSTOMER	Khách hàng mẫu 102	0900000102	hash_password_default_123
USR0000103	CUSTOMER	Khách hàng mẫu 103	0900000103	hash_password_default_123
USR0000104	CUSTOMER	Khách hàng mẫu 104	0900000104	hash_password_default_123
USR0000105	CUSTOMER	Khách hàng mẫu 105	0900000105	hash_password_default_123
USR0000106	CUSTOMER	Khách hàng mẫu 106	0900000106	hash_password_default_123
USR0000107	CUSTOMER	Khách hàng mẫu 107	0900000107	hash_password_default_123
USR0000108	CUSTOMER	Khách hàng mẫu 108	0900000108	hash_password_default_123
USR0000109	CUSTOMER	Khách hàng mẫu 109	0900000109	hash_password_default_123
USR0000110	CUSTOMER	Khách hàng mẫu 110	0900000110	hash_password_default_123
USR0000111	CUSTOMER	Khách hàng mẫu 111	0900000111	hash_password_default_123
USR0000112	CUSTOMER	Khách hàng mẫu 112	0900000112	hash_password_default_123
USR0000113	CUSTOMER	Khách hàng mẫu 113	0900000113	hash_password_default_123
USR0000114	CUSTOMER	Khách hàng mẫu 114	0900000114	hash_password_default_123
USR0000115	CUSTOMER	Khách hàng mẫu 115	0900000115	hash_password_default_123
USR0000116	CUSTOMER	Khách hàng mẫu 116	0900000116	hash_password_default_123
USR0000117	CUSTOMER	Khách hàng mẫu 117	0900000117	hash_password_default_123
USR0000118	CUSTOMER	Khách hàng mẫu 118	0900000118	hash_password_default_123
USR0000119	CUSTOMER	Khách hàng mẫu 119	0900000119	hash_password_default_123
USR0000120	CUSTOMER	Khách hàng mẫu 120	0900000120	hash_password_default_123
USR0000121	CUSTOMER	Khách hàng mẫu 121	0900000121	hash_password_default_123
USR0000122	CUSTOMER	Khách hàng mẫu 122	0900000122	hash_password_default_123
USR0000123	CUSTOMER	Khách hàng mẫu 123	0900000123	hash_password_default_123
USR0000124	CUSTOMER	Khách hàng mẫu 124	0900000124	hash_password_default_123
USR0000125	CUSTOMER	Khách hàng mẫu 125	0900000125	hash_password_default_123
USR0000126	CUSTOMER	Khách hàng mẫu 126	0900000126	hash_password_default_123
USR0000127	CUSTOMER	Khách hàng mẫu 127	0900000127	hash_password_default_123
USR0000128	CUSTOMER	Khách hàng mẫu 128	0900000128	hash_password_default_123
USR0000129	CUSTOMER	Khách hàng mẫu 129	0900000129	hash_password_default_123
USR0000130	CUSTOMER	Khách hàng mẫu 130	0900000130	hash_password_default_123
USR0000131	CUSTOMER	Khách hàng mẫu 131	0900000131	hash_password_default_123
USR0000132	CUSTOMER	Khách hàng mẫu 132	0900000132	hash_password_default_123
USR0000133	CUSTOMER	Khách hàng mẫu 133	0900000133	hash_password_default_123
USR0000134	CUSTOMER	Khách hàng mẫu 134	0900000134	hash_password_default_123
USR0000135	CUSTOMER	Khách hàng mẫu 135	0900000135	hash_password_default_123
USR0000136	CUSTOMER	Khách hàng mẫu 136	0900000136	hash_password_default_123
USR0000137	CUSTOMER	Khách hàng mẫu 137	0900000137	hash_password_default_123
USR0000138	CUSTOMER	Khách hàng mẫu 138	0900000138	hash_password_default_123
USR0000139	CUSTOMER	Khách hàng mẫu 139	0900000139	hash_password_default_123
USR0000140	CUSTOMER	Khách hàng mẫu 140	0900000140	hash_password_default_123
USR0000141	CUSTOMER	Khách hàng mẫu 141	0900000141	hash_password_default_123
USR0000142	CUSTOMER	Khách hàng mẫu 142	0900000142	hash_password_default_123
USR0000143	CUSTOMER	Khách hàng mẫu 143	0900000143	hash_password_default_123
USR0000144	CUSTOMER	Khách hàng mẫu 144	0900000144	hash_password_default_123
USR0000145	CUSTOMER	Khách hàng mẫu 145	0900000145	hash_password_default_123
USR0000146	CUSTOMER	Khách hàng mẫu 146	0900000146	hash_password_default_123
USR0000147	CUSTOMER	Khách hàng mẫu 147	0900000147	hash_password_default_123
USR0000148	CUSTOMER	Khách hàng mẫu 148	0900000148	hash_password_default_123
USR0000149	CUSTOMER	Khách hàng mẫu 149	0900000149	hash_password_default_123
USR0000150	CUSTOMER	Khách hàng mẫu 150	0900000150	hash_password_default_123
USR0000151	CUSTOMER	Khách hàng mẫu 151	0900000151	hash_password_default_123
USR0000152	CUSTOMER	Khách hàng mẫu 152	0900000152	hash_password_default_123
USR0000153	CUSTOMER	Khách hàng mẫu 153	0900000153	hash_password_default_123
USR0000154	CUSTOMER	Khách hàng mẫu 154	0900000154	hash_password_default_123
USR0000155	CUSTOMER	Khách hàng mẫu 155	0900000155	hash_password_default_123
USR0000156	CUSTOMER	Khách hàng mẫu 156	0900000156	hash_password_default_123
USR0000157	CUSTOMER	Khách hàng mẫu 157	0900000157	hash_password_default_123
USR0000158	CUSTOMER	Khách hàng mẫu 158	0900000158	hash_password_default_123
USR0000159	CUSTOMER	Khách hàng mẫu 159	0900000159	hash_password_default_123
USR0000160	CUSTOMER	Khách hàng mẫu 160	0900000160	hash_password_default_123
USR0000161	CUSTOMER	Khách hàng mẫu 161	0900000161	hash_password_default_123
USR0000162	CUSTOMER	Khách hàng mẫu 162	0900000162	hash_password_default_123
USR0000163	CUSTOMER	Khách hàng mẫu 163	0900000163	hash_password_default_123
USR0000164	CUSTOMER	Khách hàng mẫu 164	0900000164	hash_password_default_123
USR0000165	CUSTOMER	Khách hàng mẫu 165	0900000165	hash_password_default_123
USR0000166	CUSTOMER	Khách hàng mẫu 166	0900000166	hash_password_default_123
USR0000167	CUSTOMER	Khách hàng mẫu 167	0900000167	hash_password_default_123
USR0000168	CUSTOMER	Khách hàng mẫu 168	0900000168	hash_password_default_123
USR0000169	CUSTOMER	Khách hàng mẫu 169	0900000169	hash_password_default_123
USR0000170	CUSTOMER	Khách hàng mẫu 170	0900000170	hash_password_default_123
USR0000171	CUSTOMER	Khách hàng mẫu 171	0900000171	hash_password_default_123
USR0000172	CUSTOMER	Khách hàng mẫu 172	0900000172	hash_password_default_123
USR0000173	CUSTOMER	Khách hàng mẫu 173	0900000173	hash_password_default_123
USR0000174	CUSTOMER	Khách hàng mẫu 174	0900000174	hash_password_default_123
USR0000175	CUSTOMER	Khách hàng mẫu 175	0900000175	hash_password_default_123
USR0000176	CUSTOMER	Khách hàng mẫu 176	0900000176	hash_password_default_123
USR0000177	CUSTOMER	Khách hàng mẫu 177	0900000177	hash_password_default_123
USR0000178	CUSTOMER	Khách hàng mẫu 178	0900000178	hash_password_default_123
USR0000179	CUSTOMER	Khách hàng mẫu 179	0900000179	hash_password_default_123
USR0000180	CUSTOMER	Khách hàng mẫu 180	0900000180	hash_password_default_123
USR0000181	CUSTOMER	Khách hàng mẫu 181	0900000181	hash_password_default_123
USR0000182	CUSTOMER	Khách hàng mẫu 182	0900000182	hash_password_default_123
USR0000183	CUSTOMER	Khách hàng mẫu 183	0900000183	hash_password_default_123
USR0000184	CUSTOMER	Khách hàng mẫu 184	0900000184	hash_password_default_123
USR0000185	CUSTOMER	Khách hàng mẫu 185	0900000185	hash_password_default_123
USR0000186	CUSTOMER	Khách hàng mẫu 186	0900000186	hash_password_default_123
USR0000187	CUSTOMER	Khách hàng mẫu 187	0900000187	hash_password_default_123
USR0000188	CUSTOMER	Khách hàng mẫu 188	0900000188	hash_password_default_123
USR0000189	CUSTOMER	Khách hàng mẫu 189	0900000189	hash_password_default_123
USR0000190	CUSTOMER	Khách hàng mẫu 190	0900000190	hash_password_default_123
USR0000191	CUSTOMER	Khách hàng mẫu 191	0900000191	hash_password_default_123
USR0000192	CUSTOMER	Khách hàng mẫu 192	0900000192	hash_password_default_123
USR0000193	CUSTOMER	Khách hàng mẫu 193	0900000193	hash_password_default_123
USR0000194	CUSTOMER	Khách hàng mẫu 194	0900000194	hash_password_default_123
USR0000195	CUSTOMER	Khách hàng mẫu 195	0900000195	hash_password_default_123
USR0000196	CUSTOMER	Khách hàng mẫu 196	0900000196	hash_password_default_123
USR0000197	CUSTOMER	Khách hàng mẫu 197	0900000197	hash_password_default_123
USR0000198	CUSTOMER	Khách hàng mẫu 198	0900000198	hash_password_default_123
USR0000199	CUSTOMER	Khách hàng mẫu 199	0900000199	hash_password_default_123
USR0000200	CUSTOMER	Khách hàng mẫu 200	0900000200	hash_password_default_123
USR0000201	CUSTOMER	Khách hàng mẫu 201	0900000201	hash_password_default_123
USR0000202	CUSTOMER	Khách hàng mẫu 202	0900000202	hash_password_default_123
USR0000203	CUSTOMER	Khách hàng mẫu 203	0900000203	hash_password_default_123
USR0000204	CUSTOMER	Khách hàng mẫu 204	0900000204	hash_password_default_123
USR0000205	CUSTOMER	Khách hàng mẫu 205	0900000205	hash_password_default_123
USR0000206	CUSTOMER	Khách hàng mẫu 206	0900000206	hash_password_default_123
USR0000207	CUSTOMER	Khách hàng mẫu 207	0900000207	hash_password_default_123
USR0000208	CUSTOMER	Khách hàng mẫu 208	0900000208	hash_password_default_123
USR0000209	CUSTOMER	Khách hàng mẫu 209	0900000209	hash_password_default_123
USR0000210	CUSTOMER	Khách hàng mẫu 210	0900000210	hash_password_default_123
USR0000211	CUSTOMER	Khách hàng mẫu 211	0900000211	hash_password_default_123
USR0000212	CUSTOMER	Khách hàng mẫu 212	0900000212	hash_password_default_123
USR0000213	CUSTOMER	Khách hàng mẫu 213	0900000213	hash_password_default_123
USR0000214	CUSTOMER	Khách hàng mẫu 214	0900000214	hash_password_default_123
USR0000215	CUSTOMER	Khách hàng mẫu 215	0900000215	hash_password_default_123
USR0000216	CUSTOMER	Khách hàng mẫu 216	0900000216	hash_password_default_123
USR0000217	CUSTOMER	Khách hàng mẫu 217	0900000217	hash_password_default_123
USR0000218	CUSTOMER	Khách hàng mẫu 218	0900000218	hash_password_default_123
USR0000219	CUSTOMER	Khách hàng mẫu 219	0900000219	hash_password_default_123
USR0000220	CUSTOMER	Khách hàng mẫu 220	0900000220	hash_password_default_123
USR0000221	CUSTOMER	Khách hàng mẫu 221	0900000221	hash_password_default_123
USR0000222	CUSTOMER	Khách hàng mẫu 222	0900000222	hash_password_default_123
USR0000223	CUSTOMER	Khách hàng mẫu 223	0900000223	hash_password_default_123
USR0000224	CUSTOMER	Khách hàng mẫu 224	0900000224	hash_password_default_123
USR0000225	CUSTOMER	Khách hàng mẫu 225	0900000225	hash_password_default_123
USR0000226	CUSTOMER	Khách hàng mẫu 226	0900000226	hash_password_default_123
USR0000227	CUSTOMER	Khách hàng mẫu 227	0900000227	hash_password_default_123
USR0000228	CUSTOMER	Khách hàng mẫu 228	0900000228	hash_password_default_123
USR0000229	CUSTOMER	Khách hàng mẫu 229	0900000229	hash_password_default_123
USR0000230	CUSTOMER	Khách hàng mẫu 230	0900000230	hash_password_default_123
USR0000231	CUSTOMER	Khách hàng mẫu 231	0900000231	hash_password_default_123
USR0000232	CUSTOMER	Khách hàng mẫu 232	0900000232	hash_password_default_123
USR0000233	CUSTOMER	Khách hàng mẫu 233	0900000233	hash_password_default_123
USR0000234	CUSTOMER	Khách hàng mẫu 234	0900000234	hash_password_default_123
USR0000235	CUSTOMER	Khách hàng mẫu 235	0900000235	hash_password_default_123
USR0000236	CUSTOMER	Khách hàng mẫu 236	0900000236	hash_password_default_123
USR0000237	CUSTOMER	Khách hàng mẫu 237	0900000237	hash_password_default_123
USR0000238	CUSTOMER	Khách hàng mẫu 238	0900000238	hash_password_default_123
USR0000239	CUSTOMER	Khách hàng mẫu 239	0900000239	hash_password_default_123
USR0000240	CUSTOMER	Khách hàng mẫu 240	0900000240	hash_password_default_123
USR0000241	CUSTOMER	Khách hàng mẫu 241	0900000241	hash_password_default_123
USR0000242	CUSTOMER	Khách hàng mẫu 242	0900000242	hash_password_default_123
USR0000243	CUSTOMER	Khách hàng mẫu 243	0900000243	hash_password_default_123
USR0000244	CUSTOMER	Khách hàng mẫu 244	0900000244	hash_password_default_123
USR0000245	CUSTOMER	Khách hàng mẫu 245	0900000245	hash_password_default_123
USR0000246	CUSTOMER	Khách hàng mẫu 246	0900000246	hash_password_default_123
USR0000247	CUSTOMER	Khách hàng mẫu 247	0900000247	hash_password_default_123
USR0000248	CUSTOMER	Khách hàng mẫu 248	0900000248	hash_password_default_123
USR0000249	CUSTOMER	Khách hàng mẫu 249	0900000249	hash_password_default_123
USR0000250	CUSTOMER	Khách hàng mẫu 250	0900000250	hash_password_default_123
USR0000251	CUSTOMER	Khách hàng mẫu 251	0900000251	hash_password_default_123
USR0000252	CUSTOMER	Khách hàng mẫu 252	0900000252	hash_password_default_123
USR0000253	CUSTOMER	Khách hàng mẫu 253	0900000253	hash_password_default_123
USR0000254	CUSTOMER	Khách hàng mẫu 254	0900000254	hash_password_default_123
USR0000255	CUSTOMER	Khách hàng mẫu 255	0900000255	hash_password_default_123
USR0000256	CUSTOMER	Khách hàng mẫu 256	0900000256	hash_password_default_123
USR0000257	CUSTOMER	Khách hàng mẫu 257	0900000257	hash_password_default_123
USR0000258	CUSTOMER	Khách hàng mẫu 258	0900000258	hash_password_default_123
USR0000259	CUSTOMER	Khách hàng mẫu 259	0900000259	hash_password_default_123
USR0000260	CUSTOMER	Khách hàng mẫu 260	0900000260	hash_password_default_123
USR0000261	CUSTOMER	Khách hàng mẫu 261	0900000261	hash_password_default_123
USR0000262	CUSTOMER	Khách hàng mẫu 262	0900000262	hash_password_default_123
USR0000263	CUSTOMER	Khách hàng mẫu 263	0900000263	hash_password_default_123
USR0000264	CUSTOMER	Khách hàng mẫu 264	0900000264	hash_password_default_123
USR0000265	CUSTOMER	Khách hàng mẫu 265	0900000265	hash_password_default_123
USR0000266	CUSTOMER	Khách hàng mẫu 266	0900000266	hash_password_default_123
USR0000267	CUSTOMER	Khách hàng mẫu 267	0900000267	hash_password_default_123
USR0000268	CUSTOMER	Khách hàng mẫu 268	0900000268	hash_password_default_123
USR0000269	CUSTOMER	Khách hàng mẫu 269	0900000269	hash_password_default_123
USR0000270	CUSTOMER	Khách hàng mẫu 270	0900000270	hash_password_default_123
USR0000271	CUSTOMER	Khách hàng mẫu 271	0900000271	hash_password_default_123
USR0000272	CUSTOMER	Khách hàng mẫu 272	0900000272	hash_password_default_123
USR0000273	CUSTOMER	Khách hàng mẫu 273	0900000273	hash_password_default_123
USR0000274	CUSTOMER	Khách hàng mẫu 274	0900000274	hash_password_default_123
USR0000275	CUSTOMER	Khách hàng mẫu 275	0900000275	hash_password_default_123
USR0000276	CUSTOMER	Khách hàng mẫu 276	0900000276	hash_password_default_123
USR0000277	CUSTOMER	Khách hàng mẫu 277	0900000277	hash_password_default_123
USR0000278	CUSTOMER	Khách hàng mẫu 278	0900000278	hash_password_default_123
USR0000279	CUSTOMER	Khách hàng mẫu 279	0900000279	hash_password_default_123
USR0000280	CUSTOMER	Khách hàng mẫu 280	0900000280	hash_password_default_123
USR0000281	CUSTOMER	Khách hàng mẫu 281	0900000281	hash_password_default_123
USR0000282	CUSTOMER	Khách hàng mẫu 282	0900000282	hash_password_default_123
USR0000283	CUSTOMER	Khách hàng mẫu 283	0900000283	hash_password_default_123
USR0000284	CUSTOMER	Khách hàng mẫu 284	0900000284	hash_password_default_123
USR0000285	CUSTOMER	Khách hàng mẫu 285	0900000285	hash_password_default_123
USR0000286	CUSTOMER	Khách hàng mẫu 286	0900000286	hash_password_default_123
USR0000287	CUSTOMER	Khách hàng mẫu 287	0900000287	hash_password_default_123
USR0000288	CUSTOMER	Khách hàng mẫu 288	0900000288	hash_password_default_123
USR0000289	CUSTOMER	Khách hàng mẫu 289	0900000289	hash_password_default_123
USR0000290	CUSTOMER	Khách hàng mẫu 290	0900000290	hash_password_default_123
USR0000291	CUSTOMER	Khách hàng mẫu 291	0900000291	hash_password_default_123
USR0000292	CUSTOMER	Khách hàng mẫu 292	0900000292	hash_password_default_123
USR0000293	CUSTOMER	Khách hàng mẫu 293	0900000293	hash_password_default_123
USR0000294	CUSTOMER	Khách hàng mẫu 294	0900000294	hash_password_default_123
USR0000295	CUSTOMER	Khách hàng mẫu 295	0900000295	hash_password_default_123
USR0000296	CUSTOMER	Khách hàng mẫu 296	0900000296	hash_password_default_123
USR0000297	CUSTOMER	Khách hàng mẫu 297	0900000297	hash_password_default_123
USR0000298	CUSTOMER	Khách hàng mẫu 298	0900000298	hash_password_default_123
USR0000299	CUSTOMER	Khách hàng mẫu 299	0900000299	hash_password_default_123
USR0000300	CUSTOMER	Khách hàng mẫu 300	0900000300	hash_password_default_123
USR0000301	CUSTOMER	Khách hàng mẫu 301	0900000301	hash_password_default_123
USR0000302	CUSTOMER	Khách hàng mẫu 302	0900000302	hash_password_default_123
USR0000303	CUSTOMER	Khách hàng mẫu 303	0900000303	hash_password_default_123
USR0000304	CUSTOMER	Khách hàng mẫu 304	0900000304	hash_password_default_123
USR0000305	CUSTOMER	Khách hàng mẫu 305	0900000305	hash_password_default_123
USR0000306	CUSTOMER	Khách hàng mẫu 306	0900000306	hash_password_default_123
USR0000307	CUSTOMER	Khách hàng mẫu 307	0900000307	hash_password_default_123
USR0000308	CUSTOMER	Khách hàng mẫu 308	0900000308	hash_password_default_123
USR0000309	CUSTOMER	Khách hàng mẫu 309	0900000309	hash_password_default_123
USR0000310	CUSTOMER	Khách hàng mẫu 310	0900000310	hash_password_default_123
USR0000311	CUSTOMER	Khách hàng mẫu 311	0900000311	hash_password_default_123
USR0000312	CUSTOMER	Khách hàng mẫu 312	0900000312	hash_password_default_123
USR0000313	CUSTOMER	Khách hàng mẫu 313	0900000313	hash_password_default_123
USR0000314	CUSTOMER	Khách hàng mẫu 314	0900000314	hash_password_default_123
USR0000315	CUSTOMER	Khách hàng mẫu 315	0900000315	hash_password_default_123
USR0000316	CUSTOMER	Khách hàng mẫu 316	0900000316	hash_password_default_123
USR0000317	CUSTOMER	Khách hàng mẫu 317	0900000317	hash_password_default_123
USR0000318	CUSTOMER	Khách hàng mẫu 318	0900000318	hash_password_default_123
USR0000319	CUSTOMER	Khách hàng mẫu 319	0900000319	hash_password_default_123
USR0000320	CUSTOMER	Khách hàng mẫu 320	0900000320	hash_password_default_123
USR0000321	CUSTOMER	Khách hàng mẫu 321	0900000321	hash_password_default_123
USR0000322	CUSTOMER	Khách hàng mẫu 322	0900000322	hash_password_default_123
USR0000323	CUSTOMER	Khách hàng mẫu 323	0900000323	hash_password_default_123
USR0000324	CUSTOMER	Khách hàng mẫu 324	0900000324	hash_password_default_123
USR0000325	CUSTOMER	Khách hàng mẫu 325	0900000325	hash_password_default_123
USR0000326	CUSTOMER	Khách hàng mẫu 326	0900000326	hash_password_default_123
USR0000327	CUSTOMER	Khách hàng mẫu 327	0900000327	hash_password_default_123
USR0000328	CUSTOMER	Khách hàng mẫu 328	0900000328	hash_password_default_123
USR0000329	CUSTOMER	Khách hàng mẫu 329	0900000329	hash_password_default_123
USR0000330	CUSTOMER	Khách hàng mẫu 330	0900000330	hash_password_default_123
USR0000331	CUSTOMER	Khách hàng mẫu 331	0900000331	hash_password_default_123
USR0000332	CUSTOMER	Khách hàng mẫu 332	0900000332	hash_password_default_123
USR0000333	CUSTOMER	Khách hàng mẫu 333	0900000333	hash_password_default_123
USR0000334	CUSTOMER	Khách hàng mẫu 334	0900000334	hash_password_default_123
USR0000335	CUSTOMER	Khách hàng mẫu 335	0900000335	hash_password_default_123
USR0000336	CUSTOMER	Khách hàng mẫu 336	0900000336	hash_password_default_123
USR0000337	CUSTOMER	Khách hàng mẫu 337	0900000337	hash_password_default_123
USR0000338	CUSTOMER	Khách hàng mẫu 338	0900000338	hash_password_default_123
USR0000339	CUSTOMER	Khách hàng mẫu 339	0900000339	hash_password_default_123
USR0000340	CUSTOMER	Khách hàng mẫu 340	0900000340	hash_password_default_123
USR0000341	CUSTOMER	Khách hàng mẫu 341	0900000341	hash_password_default_123
USR0000342	CUSTOMER	Khách hàng mẫu 342	0900000342	hash_password_default_123
USR0000343	CUSTOMER	Khách hàng mẫu 343	0900000343	hash_password_default_123
USR0000344	CUSTOMER	Khách hàng mẫu 344	0900000344	hash_password_default_123
USR0000345	CUSTOMER	Khách hàng mẫu 345	0900000345	hash_password_default_123
USR0000346	CUSTOMER	Khách hàng mẫu 346	0900000346	hash_password_default_123
USR0000347	CUSTOMER	Khách hàng mẫu 347	0900000347	hash_password_default_123
USR0000348	CUSTOMER	Khách hàng mẫu 348	0900000348	hash_password_default_123
USR0000349	CUSTOMER	Khách hàng mẫu 349	0900000349	hash_password_default_123
USR0000350	CUSTOMER	Khách hàng mẫu 350	0900000350	hash_password_default_123
USR0000351	CUSTOMER	Khách hàng mẫu 351	0900000351	hash_password_default_123
USR0000352	CUSTOMER	Khách hàng mẫu 352	0900000352	hash_password_default_123
USR0000353	CUSTOMER	Khách hàng mẫu 353	0900000353	hash_password_default_123
USR0000354	CUSTOMER	Khách hàng mẫu 354	0900000354	hash_password_default_123
USR0000355	CUSTOMER	Khách hàng mẫu 355	0900000355	hash_password_default_123
USR0000356	CUSTOMER	Khách hàng mẫu 356	0900000356	hash_password_default_123
USR0000357	CUSTOMER	Khách hàng mẫu 357	0900000357	hash_password_default_123
USR0000358	CUSTOMER	Khách hàng mẫu 358	0900000358	hash_password_default_123
USR0000359	CUSTOMER	Khách hàng mẫu 359	0900000359	hash_password_default_123
USR0000360	CUSTOMER	Khách hàng mẫu 360	0900000360	hash_password_default_123
USR0000361	CUSTOMER	Khách hàng mẫu 361	0900000361	hash_password_default_123
USR0000362	CUSTOMER	Khách hàng mẫu 362	0900000362	hash_password_default_123
USR0000363	CUSTOMER	Khách hàng mẫu 363	0900000363	hash_password_default_123
USR0000364	CUSTOMER	Khách hàng mẫu 364	0900000364	hash_password_default_123
USR0000365	CUSTOMER	Khách hàng mẫu 365	0900000365	hash_password_default_123
USR0000366	CUSTOMER	Khách hàng mẫu 366	0900000366	hash_password_default_123
USR0000367	CUSTOMER	Khách hàng mẫu 367	0900000367	hash_password_default_123
USR0000368	CUSTOMER	Khách hàng mẫu 368	0900000368	hash_password_default_123
USR0000369	CUSTOMER	Khách hàng mẫu 369	0900000369	hash_password_default_123
USR0000370	CUSTOMER	Khách hàng mẫu 370	0900000370	hash_password_default_123
USR0000371	CUSTOMER	Khách hàng mẫu 371	0900000371	hash_password_default_123
USR0000372	CUSTOMER	Khách hàng mẫu 372	0900000372	hash_password_default_123
USR0000373	CUSTOMER	Khách hàng mẫu 373	0900000373	hash_password_default_123
USR0000374	CUSTOMER	Khách hàng mẫu 374	0900000374	hash_password_default_123
USR0000375	CUSTOMER	Khách hàng mẫu 375	0900000375	hash_password_default_123
USR0000376	CUSTOMER	Khách hàng mẫu 376	0900000376	hash_password_default_123
USR0000377	CUSTOMER	Khách hàng mẫu 377	0900000377	hash_password_default_123
USR0000378	CUSTOMER	Khách hàng mẫu 378	0900000378	hash_password_default_123
USR0000379	CUSTOMER	Khách hàng mẫu 379	0900000379	hash_password_default_123
USR0000380	CUSTOMER	Khách hàng mẫu 380	0900000380	hash_password_default_123
USR0000381	CUSTOMER	Khách hàng mẫu 381	0900000381	hash_password_default_123
USR0000382	CUSTOMER	Khách hàng mẫu 382	0900000382	hash_password_default_123
USR0000383	CUSTOMER	Khách hàng mẫu 383	0900000383	hash_password_default_123
USR0000384	CUSTOMER	Khách hàng mẫu 384	0900000384	hash_password_default_123
USR0000385	CUSTOMER	Khách hàng mẫu 385	0900000385	hash_password_default_123
USR0000386	CUSTOMER	Khách hàng mẫu 386	0900000386	hash_password_default_123
USR0000387	CUSTOMER	Khách hàng mẫu 387	0900000387	hash_password_default_123
USR0000388	CUSTOMER	Khách hàng mẫu 388	0900000388	hash_password_default_123
USR0000389	CUSTOMER	Khách hàng mẫu 389	0900000389	hash_password_default_123
USR0000390	CUSTOMER	Khách hàng mẫu 390	0900000390	hash_password_default_123
USR0000391	CUSTOMER	Khách hàng mẫu 391	0900000391	hash_password_default_123
USR0000392	CUSTOMER	Khách hàng mẫu 392	0900000392	hash_password_default_123
USR0000393	CUSTOMER	Khách hàng mẫu 393	0900000393	hash_password_default_123
USR0000394	CUSTOMER	Khách hàng mẫu 394	0900000394	hash_password_default_123
USR0000395	CUSTOMER	Khách hàng mẫu 395	0900000395	hash_password_default_123
USR0000396	CUSTOMER	Khách hàng mẫu 396	0900000396	hash_password_default_123
USR0000397	CUSTOMER	Khách hàng mẫu 397	0900000397	hash_password_default_123
USR0000398	CUSTOMER	Khách hàng mẫu 398	0900000398	hash_password_default_123
USR0000399	CUSTOMER	Khách hàng mẫu 399	0900000399	hash_password_default_123
USR0000400	CUSTOMER	Khách hàng mẫu 400	0900000400	hash_password_default_123
USR0000401	CUSTOMER	Khách hàng mẫu 401	0900000401	hash_password_default_123
USR0000402	CUSTOMER	Khách hàng mẫu 402	0900000402	hash_password_default_123
USR0000403	CUSTOMER	Khách hàng mẫu 403	0900000403	hash_password_default_123
USR0000404	CUSTOMER	Khách hàng mẫu 404	0900000404	hash_password_default_123
USR0000405	CUSTOMER	Khách hàng mẫu 405	0900000405	hash_password_default_123
USR0000406	CUSTOMER	Khách hàng mẫu 406	0900000406	hash_password_default_123
USR0000407	CUSTOMER	Khách hàng mẫu 407	0900000407	hash_password_default_123
USR0000408	CUSTOMER	Khách hàng mẫu 408	0900000408	hash_password_default_123
USR0000409	CUSTOMER	Khách hàng mẫu 409	0900000409	hash_password_default_123
USR0000410	CUSTOMER	Khách hàng mẫu 410	0900000410	hash_password_default_123
USR0000411	CUSTOMER	Khách hàng mẫu 411	0900000411	hash_password_default_123
USR0000412	CUSTOMER	Khách hàng mẫu 412	0900000412	hash_password_default_123
USR0000413	CUSTOMER	Khách hàng mẫu 413	0900000413	hash_password_default_123
USR0000414	CUSTOMER	Khách hàng mẫu 414	0900000414	hash_password_default_123
USR0000415	CUSTOMER	Khách hàng mẫu 415	0900000415	hash_password_default_123
USR0000416	CUSTOMER	Khách hàng mẫu 416	0900000416	hash_password_default_123
USR0000417	CUSTOMER	Khách hàng mẫu 417	0900000417	hash_password_default_123
USR0000418	CUSTOMER	Khách hàng mẫu 418	0900000418	hash_password_default_123
USR0000419	CUSTOMER	Khách hàng mẫu 419	0900000419	hash_password_default_123
USR0000420	CUSTOMER	Khách hàng mẫu 420	0900000420	hash_password_default_123
USR0000421	CUSTOMER	Khách hàng mẫu 421	0900000421	hash_password_default_123
USR0000422	CUSTOMER	Khách hàng mẫu 422	0900000422	hash_password_default_123
USR0000423	CUSTOMER	Khách hàng mẫu 423	0900000423	hash_password_default_123
USR0000424	CUSTOMER	Khách hàng mẫu 424	0900000424	hash_password_default_123
USR0000425	CUSTOMER	Khách hàng mẫu 425	0900000425	hash_password_default_123
USR0000426	CUSTOMER	Khách hàng mẫu 426	0900000426	hash_password_default_123
USR0000427	CUSTOMER	Khách hàng mẫu 427	0900000427	hash_password_default_123
USR0000428	CUSTOMER	Khách hàng mẫu 428	0900000428	hash_password_default_123
USR0000429	CUSTOMER	Khách hàng mẫu 429	0900000429	hash_password_default_123
USR0000430	CUSTOMER	Khách hàng mẫu 430	0900000430	hash_password_default_123
USR0000431	CUSTOMER	Khách hàng mẫu 431	0900000431	hash_password_default_123
USR0000432	CUSTOMER	Khách hàng mẫu 432	0900000432	hash_password_default_123
USR0000433	CUSTOMER	Khách hàng mẫu 433	0900000433	hash_password_default_123
USR0000434	CUSTOMER	Khách hàng mẫu 434	0900000434	hash_password_default_123
USR0000435	CUSTOMER	Khách hàng mẫu 435	0900000435	hash_password_default_123
USR0000436	CUSTOMER	Khách hàng mẫu 436	0900000436	hash_password_default_123
USR0000437	CUSTOMER	Khách hàng mẫu 437	0900000437	hash_password_default_123
USR0000438	CUSTOMER	Khách hàng mẫu 438	0900000438	hash_password_default_123
USR0000439	CUSTOMER	Khách hàng mẫu 439	0900000439	hash_password_default_123
USR0000440	CUSTOMER	Khách hàng mẫu 440	0900000440	hash_password_default_123
USR0000441	CUSTOMER	Khách hàng mẫu 441	0900000441	hash_password_default_123
USR0000442	CUSTOMER	Khách hàng mẫu 442	0900000442	hash_password_default_123
USR0000443	CUSTOMER	Khách hàng mẫu 443	0900000443	hash_password_default_123
USR0000444	CUSTOMER	Khách hàng mẫu 444	0900000444	hash_password_default_123
USR0000445	CUSTOMER	Khách hàng mẫu 445	0900000445	hash_password_default_123
USR0000446	CUSTOMER	Khách hàng mẫu 446	0900000446	hash_password_default_123
USR0000447	CUSTOMER	Khách hàng mẫu 447	0900000447	hash_password_default_123
USR0000448	CUSTOMER	Khách hàng mẫu 448	0900000448	hash_password_default_123
USR0000449	CUSTOMER	Khách hàng mẫu 449	0900000449	hash_password_default_123
USR0000450	CUSTOMER	Khách hàng mẫu 450	0900000450	hash_password_default_123
USR0000451	CUSTOMER	Khách hàng mẫu 451	0900000451	hash_password_default_123
USR0000452	CUSTOMER	Khách hàng mẫu 452	0900000452	hash_password_default_123
USR0000453	CUSTOMER	Khách hàng mẫu 453	0900000453	hash_password_default_123
USR0000454	CUSTOMER	Khách hàng mẫu 454	0900000454	hash_password_default_123
USR0000455	CUSTOMER	Khách hàng mẫu 455	0900000455	hash_password_default_123
USR0000456	CUSTOMER	Khách hàng mẫu 456	0900000456	hash_password_default_123
USR0000457	CUSTOMER	Khách hàng mẫu 457	0900000457	hash_password_default_123
USR0000458	CUSTOMER	Khách hàng mẫu 458	0900000458	hash_password_default_123
USR0000459	CUSTOMER	Khách hàng mẫu 459	0900000459	hash_password_default_123
USR0000460	CUSTOMER	Khách hàng mẫu 460	0900000460	hash_password_default_123
USR0000461	CUSTOMER	Khách hàng mẫu 461	0900000461	hash_password_default_123
USR0000462	CUSTOMER	Khách hàng mẫu 462	0900000462	hash_password_default_123
USR0000463	CUSTOMER	Khách hàng mẫu 463	0900000463	hash_password_default_123
USR0000464	CUSTOMER	Khách hàng mẫu 464	0900000464	hash_password_default_123
USR0000465	CUSTOMER	Khách hàng mẫu 465	0900000465	hash_password_default_123
USR0000466	CUSTOMER	Khách hàng mẫu 466	0900000466	hash_password_default_123
USR0000467	CUSTOMER	Khách hàng mẫu 467	0900000467	hash_password_default_123
USR0000468	CUSTOMER	Khách hàng mẫu 468	0900000468	hash_password_default_123
USR0000469	CUSTOMER	Khách hàng mẫu 469	0900000469	hash_password_default_123
USR0000470	CUSTOMER	Khách hàng mẫu 470	0900000470	hash_password_default_123
USR0000471	CUSTOMER	Khách hàng mẫu 471	0900000471	hash_password_default_123
USR0000472	CUSTOMER	Khách hàng mẫu 472	0900000472	hash_password_default_123
USR0000473	CUSTOMER	Khách hàng mẫu 473	0900000473	hash_password_default_123
USR0000474	CUSTOMER	Khách hàng mẫu 474	0900000474	hash_password_default_123
USR0000475	CUSTOMER	Khách hàng mẫu 475	0900000475	hash_password_default_123
USR0000476	CUSTOMER	Khách hàng mẫu 476	0900000476	hash_password_default_123
USR0000477	CUSTOMER	Khách hàng mẫu 477	0900000477	hash_password_default_123
USR0000478	CUSTOMER	Khách hàng mẫu 478	0900000478	hash_password_default_123
USR0000479	CUSTOMER	Khách hàng mẫu 479	0900000479	hash_password_default_123
USR0000480	CUSTOMER	Khách hàng mẫu 480	0900000480	hash_password_default_123
USR0000481	CUSTOMER	Khách hàng mẫu 481	0900000481	hash_password_default_123
USR0000482	CUSTOMER	Khách hàng mẫu 482	0900000482	hash_password_default_123
USR0000483	CUSTOMER	Khách hàng mẫu 483	0900000483	hash_password_default_123
USR0000484	CUSTOMER	Khách hàng mẫu 484	0900000484	hash_password_default_123
USR0000485	CUSTOMER	Khách hàng mẫu 485	0900000485	hash_password_default_123
USR0000486	CUSTOMER	Khách hàng mẫu 486	0900000486	hash_password_default_123
USR0000487	CUSTOMER	Khách hàng mẫu 487	0900000487	hash_password_default_123
USR0000488	CUSTOMER	Khách hàng mẫu 488	0900000488	hash_password_default_123
USR0000489	CUSTOMER	Khách hàng mẫu 489	0900000489	hash_password_default_123
USR0000490	CUSTOMER	Khách hàng mẫu 490	0900000490	hash_password_default_123
USR0000491	CUSTOMER	Khách hàng mẫu 491	0900000491	hash_password_default_123
USR0000492	CUSTOMER	Khách hàng mẫu 492	0900000492	hash_password_default_123
USR0000493	CUSTOMER	Khách hàng mẫu 493	0900000493	hash_password_default_123
USR0000494	CUSTOMER	Khách hàng mẫu 494	0900000494	hash_password_default_123
USR0000495	CUSTOMER	Khách hàng mẫu 495	0900000495	hash_password_default_123
USR0000496	CUSTOMER	Khách hàng mẫu 496	0900000496	hash_password_default_123
USR0000497	CUSTOMER	Khách hàng mẫu 497	0900000497	hash_password_default_123
USR0000498	CUSTOMER	Khách hàng mẫu 498	0900000498	hash_password_default_123
USR0000499	CUSTOMER	Khách hàng mẫu 499	0900000499	hash_password_default_123
USR0000500	CUSTOMER	Khách hàng mẫu 500	0900000500	hash_password_default_123
USR0000501	CUSTOMER	Khách hàng mẫu 501	0900000501	hash_password_default_123
USR0000502	CUSTOMER	Khách hàng mẫu 502	0900000502	hash_password_default_123
USR0000503	CUSTOMER	Khách hàng mẫu 503	0900000503	hash_password_default_123
USR0000504	CUSTOMER	Khách hàng mẫu 504	0900000504	hash_password_default_123
USR0000602	DRIVER	Tài xế mẫu 2	0800000602	hash_driver_123
USR0000603	DRIVER	Tài xế mẫu 3	0800000603	hash_driver_123
USR0000604	DRIVER	Tài xế mẫu 4	0800000604	hash_driver_123
USR0000605	DRIVER	Tài xế mẫu 5	0800000605	hash_driver_123
USR0000606	DRIVER	Tài xế mẫu 6	0800000606	hash_driver_123
USR0000607	DRIVER	Tài xế mẫu 7	0800000607	hash_driver_123
USR0000608	DRIVER	Tài xế mẫu 8	0800000608	hash_driver_123
USR0000609	DRIVER	Tài xế mẫu 9	0800000609	hash_driver_123
USR0000610	DRIVER	Tài xế mẫu 10	0800000610	hash_driver_123
USR0000611	DRIVER	Tài xế mẫu 11	0800000611	hash_driver_123
USR0000612	DRIVER	Tài xế mẫu 12	0800000612	hash_driver_123
USR0000613	DRIVER	Tài xế mẫu 13	0800000613	hash_driver_123
USR0000614	DRIVER	Tài xế mẫu 14	0800000614	hash_driver_123
USR0000615	DRIVER	Tài xế mẫu 15	0800000615	hash_driver_123
USR0000616	DRIVER	Tài xế mẫu 16	0800000616	hash_driver_123
USR0000617	DRIVER	Tài xế mẫu 17	0800000617	hash_driver_123
USR0000618	DRIVER	Tài xế mẫu 18	0800000618	hash_driver_123
USR0000619	DRIVER	Tài xế mẫu 19	0800000619	hash_driver_123
USR0000620	DRIVER	Tài xế mẫu 20	0800000620	hash_driver_123
USR0000621	DRIVER	Tài xế mẫu 21	0800000621	hash_driver_123
USR0000622	DRIVER	Tài xế mẫu 22	0800000622	hash_driver_123
USR0000623	DRIVER	Tài xế mẫu 23	0800000623	hash_driver_123
USR0000624	DRIVER	Tài xế mẫu 24	0800000624	hash_driver_123
USR0000625	DRIVER	Tài xế mẫu 25	0800000625	hash_driver_123
USR0000626	DRIVER	Tài xế mẫu 26	0800000626	hash_driver_123
USR0000627	DRIVER	Tài xế mẫu 27	0800000627	hash_driver_123
USR0000628	DRIVER	Tài xế mẫu 28	0800000628	hash_driver_123
USR0000629	DRIVER	Tài xế mẫu 29	0800000629	hash_driver_123
USR0000630	DRIVER	Tài xế mẫu 30	0800000630	hash_driver_123
USR0000631	DRIVER	Tài xế mẫu 31	0800000631	hash_driver_123
USR0000632	DRIVER	Tài xế mẫu 32	0800000632	hash_driver_123
USR0000633	DRIVER	Tài xế mẫu 33	0800000633	hash_driver_123
USR0000634	DRIVER	Tài xế mẫu 34	0800000634	hash_driver_123
USR0000635	DRIVER	Tài xế mẫu 35	0800000635	hash_driver_123
USR0000636	DRIVER	Tài xế mẫu 36	0800000636	hash_driver_123
USR0000637	DRIVER	Tài xế mẫu 37	0800000637	hash_driver_123
USR0000638	DRIVER	Tài xế mẫu 38	0800000638	hash_driver_123
USR0000639	DRIVER	Tài xế mẫu 39	0800000639	hash_driver_123
USR0000640	DRIVER	Tài xế mẫu 40	0800000640	hash_driver_123
USR0000641	DRIVER	Tài xế mẫu 41	0800000641	hash_driver_123
USR0000642	DRIVER	Tài xế mẫu 42	0800000642	hash_driver_123
USR0000643	DRIVER	Tài xế mẫu 43	0800000643	hash_driver_123
USR0000644	DRIVER	Tài xế mẫu 44	0800000644	hash_driver_123
USR0000645	DRIVER	Tài xế mẫu 45	0800000645	hash_driver_123
USR0000646	DRIVER	Tài xế mẫu 46	0800000646	hash_driver_123
USR0000647	DRIVER	Tài xế mẫu 47	0800000647	hash_driver_123
USR0000648	DRIVER	Tài xế mẫu 48	0800000648	hash_driver_123
USR0000649	DRIVER	Tài xế mẫu 49	0800000649	hash_driver_123
USR0000650	DRIVER	Tài xế mẫu 50	0800000650	hash_driver_123
USR0000701	RESTAURANT_OWNER	Chủ quán mẫu 1	0700000701	hash_owner_123
USR0000702	RESTAURANT_OWNER	Chủ quán mẫu 2	0700000702	hash_owner_123
USR0000703	RESTAURANT_OWNER	Chủ quán mẫu 3	0700000703	hash_owner_123
USR0000704	RESTAURANT_OWNER	Chủ quán mẫu 4	0700000704	hash_owner_123
USR0000705	RESTAURANT_OWNER	Chủ quán mẫu 5	0700000705	hash_owner_123
USR0000706	RESTAURANT_OWNER	Chủ quán mẫu 6	0700000706	hash_owner_123
USR0000707	RESTAURANT_OWNER	Chủ quán mẫu 7	0700000707	hash_owner_123
USR0000708	RESTAURANT_OWNER	Chủ quán mẫu 8	0700000708	hash_owner_123
USR0000709	RESTAURANT_OWNER	Chủ quán mẫu 9	0700000709	hash_owner_123
USR0000710	RESTAURANT_OWNER	Chủ quán mẫu 10	0700000710	hash_owner_123
USR0000711	RESTAURANT_OWNER	Chủ quán mẫu 11	0700000711	hash_owner_123
USR0000712	RESTAURANT_OWNER	Chủ quán mẫu 12	0700000712	hash_owner_123
USR0000713	RESTAURANT_OWNER	Chủ quán mẫu 13	0700000713	hash_owner_123
USR0000714	RESTAURANT_OWNER	Chủ quán mẫu 14	0700000714	hash_owner_123
USR0000715	RESTAURANT_OWNER	Chủ quán mẫu 15	0700000715	hash_owner_123
USR0000716	RESTAURANT_OWNER	Chủ quán mẫu 16	0700000716	hash_owner_123
USR0000717	RESTAURANT_OWNER	Chủ quán mẫu 17	0700000717	hash_owner_123
USR0000718	RESTAURANT_OWNER	Chủ quán mẫu 18	0700000718	hash_owner_123
USR0000719	RESTAURANT_OWNER	Chủ quán mẫu 19	0700000719	hash_owner_123
USR0000720	RESTAURANT_OWNER	Chủ quán mẫu 20	0700000720	hash_owner_123
USR0000721	RESTAURANT_OWNER	Chủ quán mẫu 21	0700000721	hash_owner_123
USR0000722	RESTAURANT_OWNER	Chủ quán mẫu 22	0700000722	hash_owner_123
USR0000723	RESTAURANT_OWNER	Chủ quán mẫu 23	0700000723	hash_owner_123
USR0000724	RESTAURANT_OWNER	Chủ quán mẫu 24	0700000724	hash_owner_123
USR0000725	RESTAURANT_OWNER	Chủ quán mẫu 25	0700000725	hash_owner_123
USR0000726	RESTAURANT_OWNER	Chủ quán mẫu 26	0700000726	hash_owner_123
USR0000727	RESTAURANT_OWNER	Chủ quán mẫu 27	0700000727	hash_owner_123
USR0000728	RESTAURANT_OWNER	Chủ quán mẫu 28	0700000728	hash_owner_123
USR0000729	RESTAURANT_OWNER	Chủ quán mẫu 29	0700000729	hash_owner_123
USR0000730	RESTAURANT_OWNER	Chủ quán mẫu 30	0700000730	hash_owner_123
\.


--
-- Data for Name: customer; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.customer (user_id, default_delivery_address, payment_token) FROM stdin;
USR0000001	97 Man Thiện, Phường Hiệp Phú, TP. Thủ Đức, TP.HCM	tok_visa_ptit_99
USR0000005	Số 5, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000005
USR0000006	Số 6, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000006
USR0000007	Số 7, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000007
USR0000008	Số 8, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000008
USR0000009	Số 9, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000009
USR0000010	Số 10, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000010
USR0000011	Số 11, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000011
USR0000012	Số 12, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000012
USR0000013	Số 13, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000013
USR0000014	Số 14, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000014
USR0000015	Số 15, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000015
USR0000016	Số 16, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000016
USR0000017	Số 17, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000017
USR0000018	Số 18, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000018
USR0000019	Số 19, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000019
USR0000020	Số 20, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000020
USR0000021	Số 21, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000021
USR0000022	Số 22, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000022
USR0000023	Số 23, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000023
USR0000024	Số 24, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000024
USR0000025	Số 25, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000025
USR0000026	Số 26, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000026
USR0000027	Số 27, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000027
USR0000028	Số 28, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000028
USR0000029	Số 29, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000029
USR0000030	Số 30, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000030
USR0000031	Số 31, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000031
USR0000032	Số 32, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000032
USR0000033	Số 33, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000033
USR0000034	Số 34, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000034
USR0000035	Số 35, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000035
USR0000036	Số 36, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000036
USR0000037	Số 37, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000037
USR0000038	Số 38, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000038
USR0000039	Số 39, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000039
USR0000040	Số 40, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000040
USR0000041	Số 41, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000041
USR0000042	Số 42, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000042
USR0000043	Số 43, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000043
USR0000044	Số 44, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000044
USR0000045	Số 45, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000045
USR0000046	Số 46, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000046
USR0000047	Số 47, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000047
USR0000048	Số 48, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000048
USR0000049	Số 49, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000049
USR0000050	Số 50, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000050
USR0000051	Số 51, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000051
USR0000052	Số 52, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000052
USR0000053	Số 53, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000053
USR0000054	Số 54, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000054
USR0000055	Số 55, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000055
USR0000056	Số 56, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000056
USR0000057	Số 57, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000057
USR0000058	Số 58, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000058
USR0000059	Số 59, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000059
USR0000060	Số 60, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000060
USR0000061	Số 61, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000061
USR0000062	Số 62, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000062
USR0000063	Số 63, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000063
USR0000064	Số 64, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000064
USR0000065	Số 65, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000065
USR0000066	Số 66, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000066
USR0000067	Số 67, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000067
USR0000068	Số 68, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000068
USR0000069	Số 69, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000069
USR0000070	Số 70, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000070
USR0000071	Số 71, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000071
USR0000072	Số 72, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000072
USR0000073	Số 73, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000073
USR0000074	Số 74, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000074
USR0000075	Số 75, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000075
USR0000076	Số 76, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000076
USR0000077	Số 77, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000077
USR0000078	Số 78, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000078
USR0000079	Số 79, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000079
USR0000080	Số 80, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000080
USR0000081	Số 81, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000081
USR0000082	Số 82, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000082
USR0000083	Số 83, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000083
USR0000084	Số 84, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000084
USR0000085	Số 85, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000085
USR0000086	Số 86, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000086
USR0000087	Số 87, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000087
USR0000088	Số 88, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000088
USR0000089	Số 89, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000089
USR0000090	Số 90, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000090
USR0000091	Số 91, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000091
USR0000092	Số 92, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000092
USR0000093	Số 93, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000093
USR0000094	Số 94, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000094
USR0000095	Số 95, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000095
USR0000096	Số 96, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000096
USR0000097	Số 97, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000097
USR0000098	Số 98, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000098
USR0000099	Số 99, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000099
USR0000100	Số 100, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000100
USR0000101	Số 101, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000101
USR0000102	Số 102, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000102
USR0000103	Số 103, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000103
USR0000104	Số 104, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000104
USR0000105	Số 105, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000105
USR0000106	Số 106, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000106
USR0000107	Số 107, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000107
USR0000108	Số 108, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000108
USR0000109	Số 109, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000109
USR0000110	Số 110, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000110
USR0000111	Số 111, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000111
USR0000112	Số 112, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000112
USR0000113	Số 113, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000113
USR0000114	Số 114, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000114
USR0000115	Số 115, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000115
USR0000116	Số 116, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000116
USR0000117	Số 117, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000117
USR0000118	Số 118, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000118
USR0000119	Số 119, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000119
USR0000120	Số 120, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000120
USR0000121	Số 121, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000121
USR0000122	Số 122, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000122
USR0000123	Số 123, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000123
USR0000124	Số 124, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000124
USR0000125	Số 125, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000125
USR0000126	Số 126, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000126
USR0000127	Số 127, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000127
USR0000128	Số 128, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000128
USR0000129	Số 129, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000129
USR0000130	Số 130, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000130
USR0000131	Số 131, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000131
USR0000132	Số 132, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000132
USR0000133	Số 133, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000133
USR0000134	Số 134, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000134
USR0000135	Số 135, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000135
USR0000136	Số 136, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000136
USR0000137	Số 137, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000137
USR0000138	Số 138, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000138
USR0000139	Số 139, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000139
USR0000140	Số 140, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000140
USR0000141	Số 141, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000141
USR0000142	Số 142, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000142
USR0000143	Số 143, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000143
USR0000144	Số 144, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000144
USR0000145	Số 145, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000145
USR0000146	Số 146, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000146
USR0000147	Số 147, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000147
USR0000148	Số 148, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000148
USR0000149	Số 149, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000149
USR0000150	Số 150, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000150
USR0000151	Số 151, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000151
USR0000152	Số 152, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000152
USR0000153	Số 153, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000153
USR0000154	Số 154, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000154
USR0000155	Số 155, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000155
USR0000156	Số 156, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000156
USR0000157	Số 157, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000157
USR0000158	Số 158, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000158
USR0000159	Số 159, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000159
USR0000160	Số 160, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000160
USR0000161	Số 161, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000161
USR0000162	Số 162, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000162
USR0000163	Số 163, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000163
USR0000164	Số 164, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000164
USR0000165	Số 165, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000165
USR0000166	Số 166, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000166
USR0000167	Số 167, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000167
USR0000168	Số 168, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000168
USR0000169	Số 169, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000169
USR0000170	Số 170, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000170
USR0000171	Số 171, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000171
USR0000172	Số 172, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000172
USR0000173	Số 173, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000173
USR0000174	Số 174, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000174
USR0000175	Số 175, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000175
USR0000176	Số 176, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000176
USR0000177	Số 177, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000177
USR0000178	Số 178, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000178
USR0000179	Số 179, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000179
USR0000180	Số 180, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000180
USR0000181	Số 181, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000181
USR0000182	Số 182, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000182
USR0000183	Số 183, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000183
USR0000184	Số 184, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000184
USR0000185	Số 185, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000185
USR0000186	Số 186, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000186
USR0000187	Số 187, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000187
USR0000188	Số 188, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000188
USR0000189	Số 189, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000189
USR0000190	Số 190, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000190
USR0000191	Số 191, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000191
USR0000192	Số 192, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000192
USR0000193	Số 193, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000193
USR0000194	Số 194, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000194
USR0000195	Số 195, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000195
USR0000196	Số 196, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000196
USR0000197	Số 197, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000197
USR0000198	Số 198, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000198
USR0000199	Số 199, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000199
USR0000200	Số 200, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000200
USR0000201	Số 201, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000201
USR0000202	Số 202, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000202
USR0000203	Số 203, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000203
USR0000204	Số 204, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000204
USR0000205	Số 205, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000205
USR0000206	Số 206, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000206
USR0000207	Số 207, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000207
USR0000208	Số 208, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000208
USR0000209	Số 209, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000209
USR0000210	Số 210, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000210
USR0000211	Số 211, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000211
USR0000212	Số 212, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000212
USR0000213	Số 213, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000213
USR0000214	Số 214, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000214
USR0000215	Số 215, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000215
USR0000216	Số 216, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000216
USR0000217	Số 217, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000217
USR0000218	Số 218, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000218
USR0000219	Số 219, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000219
USR0000220	Số 220, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000220
USR0000221	Số 221, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000221
USR0000222	Số 222, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000222
USR0000223	Số 223, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000223
USR0000224	Số 224, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000224
USR0000225	Số 225, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000225
USR0000226	Số 226, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000226
USR0000227	Số 227, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000227
USR0000228	Số 228, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000228
USR0000229	Số 229, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000229
USR0000230	Số 230, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000230
USR0000231	Số 231, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000231
USR0000232	Số 232, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000232
USR0000233	Số 233, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000233
USR0000234	Số 234, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000234
USR0000235	Số 235, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000235
USR0000236	Số 236, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000236
USR0000237	Số 237, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000237
USR0000238	Số 238, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000238
USR0000239	Số 239, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000239
USR0000240	Số 240, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000240
USR0000241	Số 241, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000241
USR0000242	Số 242, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000242
USR0000243	Số 243, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000243
USR0000244	Số 244, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000244
USR0000245	Số 245, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000245
USR0000246	Số 246, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000246
USR0000247	Số 247, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000247
USR0000248	Số 248, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000248
USR0000249	Số 249, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000249
USR0000250	Số 250, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000250
USR0000251	Số 251, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000251
USR0000252	Số 252, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000252
USR0000253	Số 253, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000253
USR0000254	Số 254, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000254
USR0000255	Số 255, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000255
USR0000256	Số 256, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000256
USR0000257	Số 257, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000257
USR0000258	Số 258, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000258
USR0000259	Số 259, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000259
USR0000260	Số 260, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000260
USR0000261	Số 261, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000261
USR0000262	Số 262, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000262
USR0000263	Số 263, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000263
USR0000264	Số 264, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000264
USR0000265	Số 265, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000265
USR0000266	Số 266, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000266
USR0000267	Số 267, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000267
USR0000268	Số 268, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000268
USR0000269	Số 269, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000269
USR0000270	Số 270, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000270
USR0000271	Số 271, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000271
USR0000272	Số 272, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000272
USR0000273	Số 273, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000273
USR0000274	Số 274, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000274
USR0000275	Số 275, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000275
USR0000276	Số 276, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000276
USR0000277	Số 277, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000277
USR0000278	Số 278, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000278
USR0000279	Số 279, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000279
USR0000280	Số 280, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000280
USR0000281	Số 281, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000281
USR0000282	Số 282, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000282
USR0000283	Số 283, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000283
USR0000284	Số 284, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000284
USR0000285	Số 285, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000285
USR0000286	Số 286, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000286
USR0000287	Số 287, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000287
USR0000288	Số 288, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000288
USR0000289	Số 289, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000289
USR0000290	Số 290, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000290
USR0000291	Số 291, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000291
USR0000292	Số 292, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000292
USR0000293	Số 293, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000293
USR0000294	Số 294, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000294
USR0000295	Số 295, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000295
USR0000296	Số 296, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000296
USR0000297	Số 297, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000297
USR0000298	Số 298, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000298
USR0000299	Số 299, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000299
USR0000300	Số 300, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000300
USR0000301	Số 301, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000301
USR0000302	Số 302, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000302
USR0000303	Số 303, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000303
USR0000304	Số 304, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000304
USR0000305	Số 305, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000305
USR0000306	Số 306, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000306
USR0000307	Số 307, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000307
USR0000308	Số 308, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000308
USR0000309	Số 309, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000309
USR0000310	Số 310, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000310
USR0000311	Số 311, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000311
USR0000312	Số 312, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000312
USR0000313	Số 313, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000313
USR0000314	Số 314, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000314
USR0000315	Số 315, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000315
USR0000316	Số 316, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000316
USR0000317	Số 317, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000317
USR0000318	Số 318, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000318
USR0000319	Số 319, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000319
USR0000320	Số 320, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000320
USR0000321	Số 321, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000321
USR0000322	Số 322, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000322
USR0000323	Số 323, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000323
USR0000324	Số 324, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000324
USR0000325	Số 325, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000325
USR0000326	Số 326, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000326
USR0000327	Số 327, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000327
USR0000328	Số 328, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000328
USR0000329	Số 329, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000329
USR0000330	Số 330, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000330
USR0000331	Số 331, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000331
USR0000332	Số 332, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000332
USR0000333	Số 333, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000333
USR0000334	Số 334, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000334
USR0000335	Số 335, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000335
USR0000336	Số 336, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000336
USR0000337	Số 337, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000337
USR0000338	Số 338, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000338
USR0000339	Số 339, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000339
USR0000340	Số 340, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000340
USR0000341	Số 341, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000341
USR0000342	Số 342, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000342
USR0000343	Số 343, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000343
USR0000344	Số 344, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000344
USR0000345	Số 345, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000345
USR0000346	Số 346, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000346
USR0000347	Số 347, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000347
USR0000348	Số 348, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000348
USR0000349	Số 349, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000349
USR0000350	Số 350, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000350
USR0000351	Số 351, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000351
USR0000352	Số 352, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000352
USR0000353	Số 353, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000353
USR0000354	Số 354, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000354
USR0000355	Số 355, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000355
USR0000356	Số 356, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000356
USR0000357	Số 357, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000357
USR0000358	Số 358, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000358
USR0000359	Số 359, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000359
USR0000360	Số 360, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000360
USR0000361	Số 361, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000361
USR0000362	Số 362, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000362
USR0000363	Số 363, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000363
USR0000364	Số 364, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000364
USR0000365	Số 365, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000365
USR0000366	Số 366, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000366
USR0000367	Số 367, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000367
USR0000368	Số 368, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000368
USR0000369	Số 369, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000369
USR0000370	Số 370, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000370
USR0000371	Số 371, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000371
USR0000372	Số 372, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000372
USR0000373	Số 373, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000373
USR0000374	Số 374, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000374
USR0000375	Số 375, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000375
USR0000376	Số 376, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000376
USR0000377	Số 377, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000377
USR0000378	Số 378, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000378
USR0000379	Số 379, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000379
USR0000380	Số 380, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000380
USR0000381	Số 381, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000381
USR0000382	Số 382, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000382
USR0000383	Số 383, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000383
USR0000384	Số 384, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000384
USR0000385	Số 385, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000385
USR0000386	Số 386, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000386
USR0000387	Số 387, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000387
USR0000388	Số 388, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000388
USR0000389	Số 389, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000389
USR0000390	Số 390, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000390
USR0000391	Số 391, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000391
USR0000392	Số 392, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000392
USR0000393	Số 393, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000393
USR0000394	Số 394, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000394
USR0000395	Số 395, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000395
USR0000396	Số 396, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000396
USR0000397	Số 397, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000397
USR0000398	Số 398, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000398
USR0000399	Số 399, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000399
USR0000400	Số 400, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000400
USR0000401	Số 401, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000401
USR0000402	Số 402, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000402
USR0000403	Số 403, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000403
USR0000404	Số 404, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000404
USR0000405	Số 405, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000405
USR0000406	Số 406, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000406
USR0000407	Số 407, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000407
USR0000408	Số 408, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000408
USR0000409	Số 409, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000409
USR0000410	Số 410, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000410
USR0000411	Số 411, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000411
USR0000412	Số 412, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000412
USR0000413	Số 413, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000413
USR0000414	Số 414, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000414
USR0000415	Số 415, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000415
USR0000416	Số 416, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000416
USR0000417	Số 417, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000417
USR0000418	Số 418, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000418
USR0000419	Số 419, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000419
USR0000420	Số 420, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000420
USR0000421	Số 421, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000421
USR0000422	Số 422, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000422
USR0000423	Số 423, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000423
USR0000424	Số 424, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000424
USR0000425	Số 425, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000425
USR0000426	Số 426, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000426
USR0000427	Số 427, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000427
USR0000428	Số 428, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000428
USR0000429	Số 429, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000429
USR0000430	Số 430, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000430
USR0000431	Số 431, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000431
USR0000432	Số 432, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000432
USR0000433	Số 433, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000433
USR0000434	Số 434, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000434
USR0000435	Số 435, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000435
USR0000436	Số 436, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000436
USR0000437	Số 437, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000437
USR0000438	Số 438, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000438
USR0000439	Số 439, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000439
USR0000440	Số 440, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000440
USR0000441	Số 441, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000441
USR0000442	Số 442, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000442
USR0000443	Số 443, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000443
USR0000444	Số 444, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000444
USR0000445	Số 445, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000445
USR0000446	Số 446, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000446
USR0000447	Số 447, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000447
USR0000448	Số 448, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000448
USR0000449	Số 449, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000449
USR0000450	Số 450, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000450
USR0000451	Số 451, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000451
USR0000452	Số 452, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000452
USR0000453	Số 453, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000453
USR0000454	Số 454, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000454
USR0000455	Số 455, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000455
USR0000456	Số 456, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000456
USR0000457	Số 457, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000457
USR0000458	Số 458, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000458
USR0000459	Số 459, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000459
USR0000460	Số 460, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000460
USR0000461	Số 461, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000461
USR0000462	Số 462, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000462
USR0000463	Số 463, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000463
USR0000464	Số 464, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000464
USR0000465	Số 465, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000465
USR0000466	Số 466, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000466
USR0000467	Số 467, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000467
USR0000468	Số 468, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000468
USR0000469	Số 469, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000469
USR0000470	Số 470, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000470
USR0000471	Số 471, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000471
USR0000472	Số 472, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000472
USR0000473	Số 473, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000473
USR0000474	Số 474, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000474
USR0000475	Số 475, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000475
USR0000476	Số 476, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000476
USR0000477	Số 477, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000477
USR0000478	Số 478, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000478
USR0000479	Số 479, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000479
USR0000480	Số 480, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000480
USR0000481	Số 481, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000481
USR0000482	Số 482, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000482
USR0000483	Số 483, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000483
USR0000484	Số 484, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000484
USR0000485	Số 485, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000485
USR0000486	Số 486, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000486
USR0000487	Số 487, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000487
USR0000488	Số 488, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000488
USR0000489	Số 489, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000489
USR0000490	Số 490, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000490
USR0000491	Số 491, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000491
USR0000492	Số 492, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000492
USR0000493	Số 493, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000493
USR0000494	Số 494, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000494
USR0000495	Số 495, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000495
USR0000496	Số 496, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000496
USR0000497	Số 497, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000497
USR0000498	Số 498, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000498
USR0000499	Số 499, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000499
USR0000500	Số 500, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000500
USR0000501	Số 501, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000501
USR0000502	Số 502, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000502
USR0000503	Số 503, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000503
USR0000504	Số 504, Đường Lê Văn Việt, TP. Thủ Đức, TP.HCM	tok_test_000504
\.


--
-- Data for Name: driver; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.driver (user_id, license_plate, is_active_order, location) FROM stdin;
USR0000003	59X3-888.99	f	0101000020E61000007593180456B25A40FC1873D712B22540
USR0000004	59X1-123.45	t	0101000020E6100000EE7C3F355EB25A4035EF384547B22540
USR0000601	59-X1 10601	f	0101000020E610000056D784F8F7AA5A402B7025FF47942540
USR0000602	59-X1 10602	f	0101000020E61000005CD336ABE8AB5A40C86E77FA0EB72540
USR0000603	59-X1 10603	f	0101000020E6100000569BD6A3E1AD5A408FAEFD2388AE2540
USR0000604	59-X1 10604	t	0101000020E6100000FE5379C2CBA95A40C0DB9DF404A62540
USR0000605	59-X1 10605	f	0101000020E610000058CBED8D19B25A401D735B98D1A22540
USR0000606	59-X1 10606	f	0101000020E610000046DFD2F8FBAD5A40A48EBCC436902540
USR0000607	59-X1 10607	f	0101000020E61000004E05790F23AB5A40CCE33BEFA9822540
USR0000608	59-X1 10608	t	0101000020E610000068C293A5A6B15A406375235CC1932540
USR0000609	59-X1 10609	f	0101000020E6100000D571489CBBB15A401EDCD9D28EB32540
USR0000610	59-X1 10610	f	0101000020E6100000D30BAC0922B05A40601B37CBB8812540
USR0000611	59-X1 10611	f	0101000020E61000002EC7019FB9B25A409A3373BC07942540
USR0000612	59-X1 10612	t	0101000020E6100000D33EFB2762AE5A40ED14A985A2962540
USR0000613	59-X1 10613	f	0101000020E6100000DEC205CBFBA95A4095E98A0752942540
USR0000614	59-X1 10614	f	0101000020E6100000E5C0A3FE15AF5A40C8BD10F2DD902540
USR0000615	59-X1 10615	f	0101000020E6100000CAA14CB452AE5A401022CF6121822540
USR0000616	59-X1 10616	t	0101000020E6100000A6DF548285AF5A40612E1FA989B12540
USR0000617	59-X1 10617	f	0101000020E610000094CAF8FA08B35A4089B33C7F30A62540
USR0000618	59-X1 10618	f	0101000020E6100000453408300AB25A408F66D8DCB69D2540
USR0000619	59-X1 10619	f	0101000020E61000001EA067DFC1AE5A406F5493E43FB32540
USR0000620	59-X1 10620	t	0101000020E610000052B7863EF2B05A40BC0592F0F88A2540
USR0000621	59-X1 10621	f	0101000020E61000003EFAF7B55DB25A407945A10333A22540
USR0000622	59-X1 10622	f	0101000020E61000004D81F92B57AD5A4056AA852C99862540
USR0000623	59-X1 10623	f	0101000020E6100000D208BC7D39AC5A400098EC27AC9B2540
USR0000624	59-X1 10624	t	0101000020E6100000F391D0CDF6AC5A403D8088003F962540
USR0000625	59-X1 10625	f	0101000020E6100000CE2C135143B15A40D1347AEEACB72540
USR0000626	59-X1 10626	f	0101000020E6100000D3B425358AB15A40B98016298E912540
USR0000627	59-X1 10627	f	0101000020E6100000EA306C9049AD5A40EF990956A6932540
USR0000628	59-X1 10628	t	0101000020E6100000B4927FCFCDB25A40CCB96AE24CBD2540
USR0000629	59-X1 10629	f	0101000020E6100000E4EA132050B25A406C90F0F862B32540
USR0000630	59-X1 10630	f	0101000020E610000039D6A623E8B15A404B1D3AE313802540
USR0000631	59-X1 10631	f	0101000020E6100000010611A98DAB5A40BAD4EBF1A38A2540
USR0000632	59-X1 10632	t	0101000020E61000007C58F4A2A2AE5A40DEDF6C1FDA8A2540
USR0000633	59-X1 10633	f	0101000020E6100000A4A586BB55B25A40B2F78A3693B32540
USR0000634	59-X1 10634	f	0101000020E610000084951579C4AC5A40C0F49C3DA5872540
USR0000635	59-X1 10635	f	0101000020E6100000F528BA52D6A95A4066E6682CADB32540
USR0000636	59-X1 10636	t	0101000020E61000004C71F801A3AC5A40BFDE92DB71A82540
USR0000637	59-X1 10637	f	0101000020E61000001BA43C71B8B25A407552ABCAF3B12540
USR0000638	59-X1 10638	f	0101000020E6100000533F7F5F79B25A40F227F7E83B982540
USR0000639	59-X1 10639	f	0101000020E6100000C1FEBFA1D7B25A409D2BA96C1F9C2540
USR0000640	59-X1 10640	t	0101000020E6100000D5AD446B92AC5A40C9E203CBCBAC2540
USR0000641	59-X1 10641	f	0101000020E61000003BDD5C7172AF5A40D0068CD8C7942540
USR0000642	59-X1 10642	f	0101000020E6100000B3CA53DA9AB05A40468AB506E8822540
USR0000643	59-X1 10643	f	0101000020E61000006652686DC6AB5A40EDA48CEF59B42540
USR0000644	59-X1 10644	t	0101000020E610000011467D9EABB05A40A3192836D3A12540
USR0000645	59-X1 10645	f	0101000020E6100000AF7FA6F5F3AF5A40DCBB2888CFAF2540
USR0000646	59-X1 10646	f	0101000020E610000050AA1DE5DFAD5A40DB0560C643B82540
USR0000647	59-X1 10647	f	0101000020E61000001A63EFA803AB5A4086E4963F51B32540
USR0000648	59-X1 10648	t	0101000020E610000076B82FD157AE5A40A1AB7E76F9BB2540
USR0000649	59-X1 10649	f	0101000020E6100000651566B96BAD5A405F3C9E848CA42540
USR0000650	59-X1 10650	f	0101000020E6100000EB5013AA94AE5A403A82A06389892540
\.


--
-- Data for Name: menu_item; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.menu_item (item_id, restaurant_id, item_name, current_price, stock_status) FROM stdin;
ITM0000001	RES0000001	Cơm Sườn Bì Chả Đặc Biệt	55000	AVAILABLE
ITM0000002	RES0000001	Trà Đào Cam Sả	25000	AVAILABLE
ITM0000003	RES0000001	Canh Khổ Qua Nhồi Thịt	20000	OUT_OF_STOCK
ITM0000010	RES0000005	Phần Đặc Biệt - Phở Bò Gia Truyền 1	55000	AVAILABLE
ITM0000011	RES0000005	Phần Truyền Thống - Phở Bò Gia Truyền 1	40000	AVAILABLE
ITM0000012	RES0000005	Combo Tiết Kiệm - Phở Bò Gia Truyền 1	65000	AVAILABLE
ITM0000013	RES0000005	Món Thêm / Topping - Phở Bò Gia Truyền 1	15000	AVAILABLE
ITM0000014	RES0000005	Nước Giải Khát - Phở Bò Gia Truyền 1	20000	AVAILABLE
ITM0000015	RES0000006	Phần Đặc Biệt - Bún Bò Huế 2	55000	AVAILABLE
ITM0000016	RES0000006	Phần Truyền Thống - Bún Bò Huế 2	40000	AVAILABLE
ITM0000017	RES0000006	Combo Tiết Kiệm - Bún Bò Huế 2	65000	AVAILABLE
ITM0000018	RES0000006	Món Thêm / Topping - Bún Bò Huế 2	15000	AVAILABLE
ITM0000019	RES0000006	Nước Giải Khát - Bún Bò Huế 2	20000	AVAILABLE
ITM0000020	RES0000007	Phần Đặc Biệt - Trà Sữa & Ăn Vặt 3	55000	AVAILABLE
ITM0000021	RES0000007	Phần Truyền Thống - Trà Sữa & Ăn Vặt 3	40000	AVAILABLE
ITM0000022	RES0000007	Combo Tiết Kiệm - Trà Sữa & Ăn Vặt 3	65000	AVAILABLE
ITM0000023	RES0000007	Món Thêm / Topping - Trà Sữa & Ăn Vặt 3	15000	AVAILABLE
ITM0000024	RES0000007	Nước Giải Khát - Trà Sữa & Ăn Vặt 3	20000	AVAILABLE
ITM0000025	RES0000008	Phần Đặc Biệt - Gà Rán & Burger 4	55000	AVAILABLE
ITM0000026	RES0000008	Phần Truyền Thống - Gà Rán & Burger 4	40000	AVAILABLE
ITM0000027	RES0000008	Combo Tiết Kiệm - Gà Rán & Burger 4	65000	AVAILABLE
ITM0000028	RES0000008	Món Thêm / Topping - Gà Rán & Burger 4	15000	AVAILABLE
ITM0000029	RES0000008	Nước Giải Khát - Gà Rán & Burger 4	20000	AVAILABLE
ITM0000030	RES0000009	Phần Đặc Biệt - Cơm Tấm Sài Gòn 5	55000	AVAILABLE
ITM0000031	RES0000009	Phần Truyền Thống - Cơm Tấm Sài Gòn 5	40000	AVAILABLE
ITM0000032	RES0000009	Combo Tiết Kiệm - Cơm Tấm Sài Gòn 5	65000	AVAILABLE
ITM0000033	RES0000009	Món Thêm / Topping - Cơm Tấm Sài Gòn 5	15000	AVAILABLE
ITM0000034	RES0000009	Nước Giải Khát - Cơm Tấm Sài Gòn 5	20000	AVAILABLE
ITM0000035	RES0000010	Phần Đặc Biệt - Phở Bò Gia Truyền 6	55000	AVAILABLE
ITM0000036	RES0000010	Phần Truyền Thống - Phở Bò Gia Truyền 6	40000	AVAILABLE
ITM0000037	RES0000010	Combo Tiết Kiệm - Phở Bò Gia Truyền 6	65000	AVAILABLE
ITM0000038	RES0000010	Món Thêm / Topping - Phở Bò Gia Truyền 6	15000	AVAILABLE
ITM0000039	RES0000010	Nước Giải Khát - Phở Bò Gia Truyền 6	20000	AVAILABLE
ITM0000040	RES0000011	Phần Đặc Biệt - Bún Bò Huế 7	55000	AVAILABLE
ITM0000041	RES0000011	Phần Truyền Thống - Bún Bò Huế 7	40000	AVAILABLE
ITM0000042	RES0000011	Combo Tiết Kiệm - Bún Bò Huế 7	65000	AVAILABLE
ITM0000043	RES0000011	Món Thêm / Topping - Bún Bò Huế 7	15000	AVAILABLE
ITM0000044	RES0000011	Nước Giải Khát - Bún Bò Huế 7	20000	AVAILABLE
ITM0000045	RES0000012	Phần Đặc Biệt - Trà Sữa & Ăn Vặt 8	55000	AVAILABLE
ITM0000046	RES0000012	Phần Truyền Thống - Trà Sữa & Ăn Vặt 8	40000	AVAILABLE
ITM0000047	RES0000012	Combo Tiết Kiệm - Trà Sữa & Ăn Vặt 8	65000	AVAILABLE
ITM0000048	RES0000012	Món Thêm / Topping - Trà Sữa & Ăn Vặt 8	15000	AVAILABLE
ITM0000049	RES0000012	Nước Giải Khát - Trà Sữa & Ăn Vặt 8	20000	AVAILABLE
ITM0000050	RES0000013	Phần Đặc Biệt - Gà Rán & Burger 9	55000	AVAILABLE
ITM0000051	RES0000013	Phần Truyền Thống - Gà Rán & Burger 9	40000	AVAILABLE
ITM0000052	RES0000013	Combo Tiết Kiệm - Gà Rán & Burger 9	65000	AVAILABLE
ITM0000053	RES0000013	Món Thêm / Topping - Gà Rán & Burger 9	15000	AVAILABLE
ITM0000054	RES0000013	Nước Giải Khát - Gà Rán & Burger 9	20000	AVAILABLE
ITM0000055	RES0000014	Phần Đặc Biệt - Cơm Tấm Sài Gòn 10	55000	AVAILABLE
ITM0000056	RES0000014	Phần Truyền Thống - Cơm Tấm Sài Gòn 10	40000	AVAILABLE
ITM0000057	RES0000014	Combo Tiết Kiệm - Cơm Tấm Sài Gòn 10	65000	AVAILABLE
ITM0000058	RES0000014	Món Thêm / Topping - Cơm Tấm Sài Gòn 10	15000	AVAILABLE
ITM0000059	RES0000014	Nước Giải Khát - Cơm Tấm Sài Gòn 10	20000	AVAILABLE
ITM0000060	RES0000015	Phần Đặc Biệt - Phở Bò Gia Truyền 11	55000	AVAILABLE
ITM0000061	RES0000015	Phần Truyền Thống - Phở Bò Gia Truyền 11	40000	AVAILABLE
ITM0000062	RES0000015	Combo Tiết Kiệm - Phở Bò Gia Truyền 11	65000	AVAILABLE
ITM0000063	RES0000015	Món Thêm / Topping - Phở Bò Gia Truyền 11	15000	AVAILABLE
ITM0000064	RES0000015	Nước Giải Khát - Phở Bò Gia Truyền 11	20000	AVAILABLE
ITM0000065	RES0000016	Phần Đặc Biệt - Bún Bò Huế 12	55000	AVAILABLE
ITM0000066	RES0000016	Phần Truyền Thống - Bún Bò Huế 12	40000	AVAILABLE
ITM0000067	RES0000016	Combo Tiết Kiệm - Bún Bò Huế 12	65000	AVAILABLE
ITM0000068	RES0000016	Món Thêm / Topping - Bún Bò Huế 12	15000	AVAILABLE
ITM0000069	RES0000016	Nước Giải Khát - Bún Bò Huế 12	20000	AVAILABLE
ITM0000070	RES0000017	Phần Đặc Biệt - Trà Sữa & Ăn Vặt 13	55000	AVAILABLE
ITM0000071	RES0000017	Phần Truyền Thống - Trà Sữa & Ăn Vặt 13	40000	AVAILABLE
ITM0000072	RES0000017	Combo Tiết Kiệm - Trà Sữa & Ăn Vặt 13	65000	AVAILABLE
ITM0000073	RES0000017	Món Thêm / Topping - Trà Sữa & Ăn Vặt 13	15000	AVAILABLE
ITM0000074	RES0000017	Nước Giải Khát - Trà Sữa & Ăn Vặt 13	20000	AVAILABLE
ITM0000075	RES0000018	Phần Đặc Biệt - Gà Rán & Burger 14	55000	AVAILABLE
ITM0000076	RES0000018	Phần Truyền Thống - Gà Rán & Burger 14	40000	AVAILABLE
ITM0000077	RES0000018	Combo Tiết Kiệm - Gà Rán & Burger 14	65000	AVAILABLE
ITM0000078	RES0000018	Món Thêm / Topping - Gà Rán & Burger 14	15000	AVAILABLE
ITM0000079	RES0000018	Nước Giải Khát - Gà Rán & Burger 14	20000	AVAILABLE
ITM0000080	RES0000019	Phần Đặc Biệt - Cơm Tấm Sài Gòn 15	55000	AVAILABLE
ITM0000081	RES0000019	Phần Truyền Thống - Cơm Tấm Sài Gòn 15	40000	AVAILABLE
ITM0000082	RES0000019	Combo Tiết Kiệm - Cơm Tấm Sài Gòn 15	65000	AVAILABLE
ITM0000083	RES0000019	Món Thêm / Topping - Cơm Tấm Sài Gòn 15	15000	AVAILABLE
ITM0000084	RES0000019	Nước Giải Khát - Cơm Tấm Sài Gòn 15	20000	AVAILABLE
ITM0000085	RES0000020	Phần Đặc Biệt - Phở Bò Gia Truyền 16	55000	AVAILABLE
ITM0000086	RES0000020	Phần Truyền Thống - Phở Bò Gia Truyền 16	40000	AVAILABLE
ITM0000087	RES0000020	Combo Tiết Kiệm - Phở Bò Gia Truyền 16	65000	AVAILABLE
ITM0000088	RES0000020	Món Thêm / Topping - Phở Bò Gia Truyền 16	15000	AVAILABLE
ITM0000089	RES0000020	Nước Giải Khát - Phở Bò Gia Truyền 16	20000	AVAILABLE
ITM0000090	RES0000021	Phần Đặc Biệt - Bún Bò Huế 17	55000	AVAILABLE
ITM0000091	RES0000021	Phần Truyền Thống - Bún Bò Huế 17	40000	AVAILABLE
ITM0000092	RES0000021	Combo Tiết Kiệm - Bún Bò Huế 17	65000	AVAILABLE
ITM0000093	RES0000021	Món Thêm / Topping - Bún Bò Huế 17	15000	AVAILABLE
ITM0000094	RES0000021	Nước Giải Khát - Bún Bò Huế 17	20000	AVAILABLE
ITM0000095	RES0000022	Phần Đặc Biệt - Trà Sữa & Ăn Vặt 18	55000	AVAILABLE
ITM0000096	RES0000022	Phần Truyền Thống - Trà Sữa & Ăn Vặt 18	40000	AVAILABLE
ITM0000097	RES0000022	Combo Tiết Kiệm - Trà Sữa & Ăn Vặt 18	65000	AVAILABLE
ITM0000098	RES0000022	Món Thêm / Topping - Trà Sữa & Ăn Vặt 18	15000	AVAILABLE
ITM0000099	RES0000022	Nước Giải Khát - Trà Sữa & Ăn Vặt 18	20000	AVAILABLE
ITM0000100	RES0000023	Phần Đặc Biệt - Gà Rán & Burger 19	55000	AVAILABLE
ITM0000101	RES0000023	Phần Truyền Thống - Gà Rán & Burger 19	40000	AVAILABLE
ITM0000102	RES0000023	Combo Tiết Kiệm - Gà Rán & Burger 19	65000	AVAILABLE
ITM0000103	RES0000023	Món Thêm / Topping - Gà Rán & Burger 19	15000	AVAILABLE
ITM0000104	RES0000023	Nước Giải Khát - Gà Rán & Burger 19	20000	AVAILABLE
ITM0000105	RES0000024	Phần Đặc Biệt - Cơm Tấm Sài Gòn 20	55000	AVAILABLE
ITM0000106	RES0000024	Phần Truyền Thống - Cơm Tấm Sài Gòn 20	40000	AVAILABLE
ITM0000107	RES0000024	Combo Tiết Kiệm - Cơm Tấm Sài Gòn 20	65000	AVAILABLE
ITM0000108	RES0000024	Món Thêm / Topping - Cơm Tấm Sài Gòn 20	15000	AVAILABLE
ITM0000109	RES0000024	Nước Giải Khát - Cơm Tấm Sài Gòn 20	20000	AVAILABLE
ITM0000110	RES0000025	Phần Đặc Biệt - Phở Bò Gia Truyền 21	55000	AVAILABLE
ITM0000111	RES0000025	Phần Truyền Thống - Phở Bò Gia Truyền 21	40000	AVAILABLE
ITM0000112	RES0000025	Combo Tiết Kiệm - Phở Bò Gia Truyền 21	65000	AVAILABLE
ITM0000113	RES0000025	Món Thêm / Topping - Phở Bò Gia Truyền 21	15000	AVAILABLE
ITM0000114	RES0000025	Nước Giải Khát - Phở Bò Gia Truyền 21	20000	AVAILABLE
ITM0000115	RES0000026	Phần Đặc Biệt - Bún Bò Huế 22	55000	AVAILABLE
ITM0000116	RES0000026	Phần Truyền Thống - Bún Bò Huế 22	40000	AVAILABLE
ITM0000117	RES0000026	Combo Tiết Kiệm - Bún Bò Huế 22	65000	AVAILABLE
ITM0000118	RES0000026	Món Thêm / Topping - Bún Bò Huế 22	15000	AVAILABLE
ITM0000119	RES0000026	Nước Giải Khát - Bún Bò Huế 22	20000	AVAILABLE
ITM0000120	RES0000027	Phần Đặc Biệt - Trà Sữa & Ăn Vặt 23	55000	AVAILABLE
ITM0000121	RES0000027	Phần Truyền Thống - Trà Sữa & Ăn Vặt 23	40000	AVAILABLE
ITM0000122	RES0000027	Combo Tiết Kiệm - Trà Sữa & Ăn Vặt 23	65000	AVAILABLE
ITM0000123	RES0000027	Món Thêm / Topping - Trà Sữa & Ăn Vặt 23	15000	AVAILABLE
ITM0000124	RES0000027	Nước Giải Khát - Trà Sữa & Ăn Vặt 23	20000	AVAILABLE
ITM0000125	RES0000028	Phần Đặc Biệt - Gà Rán & Burger 24	55000	AVAILABLE
ITM0000126	RES0000028	Phần Truyền Thống - Gà Rán & Burger 24	40000	AVAILABLE
ITM0000127	RES0000028	Combo Tiết Kiệm - Gà Rán & Burger 24	65000	AVAILABLE
ITM0000128	RES0000028	Món Thêm / Topping - Gà Rán & Burger 24	15000	AVAILABLE
ITM0000129	RES0000028	Nước Giải Khát - Gà Rán & Burger 24	20000	AVAILABLE
ITM0000130	RES0000029	Phần Đặc Biệt - Cơm Tấm Sài Gòn 25	55000	AVAILABLE
ITM0000131	RES0000029	Phần Truyền Thống - Cơm Tấm Sài Gòn 25	40000	AVAILABLE
ITM0000132	RES0000029	Combo Tiết Kiệm - Cơm Tấm Sài Gòn 25	65000	AVAILABLE
ITM0000133	RES0000029	Món Thêm / Topping - Cơm Tấm Sài Gòn 25	15000	AVAILABLE
ITM0000134	RES0000029	Nước Giải Khát - Cơm Tấm Sài Gòn 25	20000	AVAILABLE
ITM0000135	RES0000030	Phần Đặc Biệt - Phở Bò Gia Truyền 26	55000	AVAILABLE
ITM0000136	RES0000030	Phần Truyền Thống - Phở Bò Gia Truyền 26	40000	AVAILABLE
ITM0000137	RES0000030	Combo Tiết Kiệm - Phở Bò Gia Truyền 26	65000	AVAILABLE
ITM0000138	RES0000030	Món Thêm / Topping - Phở Bò Gia Truyền 26	15000	AVAILABLE
ITM0000139	RES0000030	Nước Giải Khát - Phở Bò Gia Truyền 26	20000	AVAILABLE
ITM0000140	RES0000031	Phần Đặc Biệt - Bún Bò Huế 27	55000	AVAILABLE
ITM0000141	RES0000031	Phần Truyền Thống - Bún Bò Huế 27	40000	AVAILABLE
ITM0000142	RES0000031	Combo Tiết Kiệm - Bún Bò Huế 27	65000	AVAILABLE
ITM0000143	RES0000031	Món Thêm / Topping - Bún Bò Huế 27	15000	AVAILABLE
ITM0000144	RES0000031	Nước Giải Khát - Bún Bò Huế 27	20000	AVAILABLE
ITM0000145	RES0000032	Phần Đặc Biệt - Trà Sữa & Ăn Vặt 28	55000	AVAILABLE
ITM0000146	RES0000032	Phần Truyền Thống - Trà Sữa & Ăn Vặt 28	40000	AVAILABLE
ITM0000147	RES0000032	Combo Tiết Kiệm - Trà Sữa & Ăn Vặt 28	65000	AVAILABLE
ITM0000148	RES0000032	Món Thêm / Topping - Trà Sữa & Ăn Vặt 28	15000	AVAILABLE
ITM0000149	RES0000032	Nước Giải Khát - Trà Sữa & Ăn Vặt 28	20000	AVAILABLE
ITM0000150	RES0000033	Phần Đặc Biệt - Gà Rán & Burger 29	55000	AVAILABLE
ITM0000151	RES0000033	Phần Truyền Thống - Gà Rán & Burger 29	40000	AVAILABLE
ITM0000152	RES0000033	Combo Tiết Kiệm - Gà Rán & Burger 29	65000	AVAILABLE
ITM0000153	RES0000033	Món Thêm / Topping - Gà Rán & Burger 29	15000	AVAILABLE
ITM0000154	RES0000033	Nước Giải Khát - Gà Rán & Burger 29	20000	AVAILABLE
ITM0000155	RES0000034	Phần Đặc Biệt - Cơm Tấm Sài Gòn 30	55000	AVAILABLE
ITM0000156	RES0000034	Phần Truyền Thống - Cơm Tấm Sài Gòn 30	40000	AVAILABLE
ITM0000157	RES0000034	Combo Tiết Kiệm - Cơm Tấm Sài Gòn 30	65000	AVAILABLE
ITM0000158	RES0000034	Món Thêm / Topping - Cơm Tấm Sài Gòn 30	15000	AVAILABLE
ITM0000159	RES0000034	Nước Giải Khát - Cơm Tấm Sài Gòn 30	20000	AVAILABLE
\.


--
-- Data for Name: order_item; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.order_item (order_id, item_id, quantity, unit_price) FROM stdin;
\.


--
-- Data for Name: restaurant; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.restaurant (restaurant_id, owner_id, restaurant_name, address, location) FROM stdin;
RES0000001	USR0000002	Cơm Tấm Sài Gòn F&F	11 Nguyễn Đình Chiểu, Quận 1, TP.HCM	0101000020E61000000AD7A3703DB25A408B6CE7FBA9B12540
RES0000005	USR0000701	Phở Bò Gia Truyền 1	Số 101 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E6100000696DD20E43AF5A40B707C1A718902540
RES0000006	USR0000702	Bún Bò Huế 2	Số 102 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000001F44B8E618AB5A40951AC549B9B52540
RES0000007	USR0000703	Trà Sữa & Ăn Vặt 3	Số 103 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000000D5A0FF328AF5A4054EBA8F664A62540
RES0000008	USR0000704	Gà Rán & Burger 4	Số 104 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000003F8D1E6EDAB05A40C024C91E02A62540
RES0000009	USR0000705	Cơm Tấm Sài Gòn 5	Số 105 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000005237C3B052AD5A400EC5F49DCCB62540
RES0000010	USR0000706	Phở Bò Gia Truyền 6	Số 106 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000008DA72E6CD8AE5A407AF7D65E8DA92540
RES0000011	USR0000707	Bún Bò Huế 7	Số 107 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E6100000B97462EF12AF5A409E02AAEDF5AB2540
RES0000012	USR0000708	Trà Sữa & Ăn Vặt 8	Số 108 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E610000044F0D2FFAAAA5A407EA59649B58F2540
RES0000013	USR0000709	Gà Rán & Burger 9	Số 109 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000002EB89BBF3AAB5A40DDF422B4B9972540
RES0000014	USR0000710	Cơm Tấm Sài Gòn 10	Số 110 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000001A561D53B9AC5A404DA1C01B49B72540
RES0000015	USR0000711	Phở Bò Gia Truyền 11	Số 111 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E6100000A3EBDCF210AB5A408E95AEBD2A8A2540
RES0000016	USR0000712	Bún Bò Huế 12	Số 112 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E610000034D2E0E111AB5A40132161DE0D902540
RES0000017	USR0000713	Trà Sữa & Ăn Vặt 13	Số 113 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000008F56E0FDBCAB5A40D34589FCA1A02540
RES0000018	USR0000714	Gà Rán & Burger 14	Số 114 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E610000007D5B4278DAE5A404C10DF499F9C2540
RES0000019	USR0000715	Cơm Tấm Sài Gòn 15	Số 115 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000000E5EB0A02BAE5A400F65415C12BA2540
RES0000020	USR0000716	Phở Bò Gia Truyền 16	Số 116 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E610000055E6BB9034B05A4050E1ABD7BC962540
RES0000021	USR0000717	Bún Bò Huế 17	Số 117 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000000E70E7CE74AD5A406BBBC11DC3822540
RES0000022	USR0000718	Trà Sữa & Ăn Vặt 18	Số 118 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E6100000469A338F49AE5A4031260AC533A32540
RES0000023	USR0000719	Gà Rán & Burger 19	Số 119 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000003B32021EB6AE5A405E20F38793852540
RES0000024	USR0000720	Cơm Tấm Sài Gòn 20	Số 120 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E6100000121769C414B05A408187BF62C38D2540
RES0000025	USR0000721	Phở Bò Gia Truyền 21	Số 121 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000003FB1FBDAA8AA5A40C33966A51CA82540
RES0000026	USR0000722	Bún Bò Huế 22	Số 122 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E6100000EF3C272C12AB5A40E954F9253BA52540
RES0000027	USR0000723	Trà Sữa & Ăn Vặt 23	Số 123 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E610000055A16A0730B25A40B99F741F448C2540
RES0000028	USR0000724	Gà Rán & Burger 24	Số 124 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E6100000F113DA8AFFAC5A400CF4F814A0932540
RES0000029	USR0000725	Cơm Tấm Sài Gòn 25	Số 125 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E6100000E68572CB05AD5A40AC7257D3E69F2540
RES0000030	USR0000726	Phở Bò Gia Truyền 26	Số 126 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E6100000439075C7C7B15A40C154843F4EA82540
RES0000031	USR0000727	Bún Bò Huế 27	Số 127 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000001CF5FD9E8AB05A409E62C9F8FBA82540
RES0000032	USR0000728	Trà Sữa & Ăn Vặt 28	Số 128 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000006E967DCEFEAF5A40D2174B1A38AF2540
RES0000033	USR0000729	Gà Rán & Burger 29	Số 129 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E61000001819F5CAC0B25A40CE96DC2A6D9E2540
RES0000034	USR0000730	Cơm Tấm Sài Gòn 30	Số 130 Đường Võ Văn Ngân, TP. Thủ Đức, TP.HCM	0101000020E6100000ACA44B67ABA95A4007D1E9DBD0A12540
\.


--
-- Data for Name: restaurant_owner; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.restaurant_owner (user_id, tax_id) FROM stdin;
USR0000002	0312345678
USR0000701	0300000701
USR0000702	0300000702
USR0000703	0300000703
USR0000704	0300000704
USR0000705	0300000705
USR0000706	0300000706
USR0000707	0300000707
USR0000708	0300000708
USR0000709	0300000709
USR0000710	0300000710
USR0000711	0300000711
USR0000712	0300000712
USR0000713	0300000713
USR0000714	0300000714
USR0000715	0300000715
USR0000716	0300000716
USR0000717	0300000717
USR0000718	0300000718
USR0000719	0300000719
USR0000720	0300000720
USR0000721	0300000721
USR0000722	0300000722
USR0000723	0300000723
USR0000724	0300000724
USR0000725	0300000725
USR0000726	0300000726
USR0000727	0300000727
USR0000728	0300000728
USR0000729	0300000729
USR0000730	0300000730
\.


--
-- Data for Name: spatial_ref_sys; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.spatial_ref_sys (srid, auth_name, auth_srid, srtext, proj4text) FROM stdin;
\.


--
-- Name: ORDER ORDER_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."ORDER"
    ADD CONSTRAINT "ORDER_pkey" PRIMARY KEY (order_id);


--
-- Name: USER USER_phone_number_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."USER"
    ADD CONSTRAINT "USER_phone_number_key" UNIQUE (phone_number);


--
-- Name: USER USER_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."USER"
    ADD CONSTRAINT "USER_pkey" PRIMARY KEY (user_id);


--
-- Name: customer customer_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_pkey PRIMARY KEY (user_id);


--
-- Name: driver driver_license_plate_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.driver
    ADD CONSTRAINT driver_license_plate_key UNIQUE (license_plate);


--
-- Name: driver driver_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.driver
    ADD CONSTRAINT driver_pkey PRIMARY KEY (user_id);


--
-- Name: menu_item menu_item_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.menu_item
    ADD CONSTRAINT menu_item_pkey PRIMARY KEY (item_id);


--
-- Name: order_item order_item_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_item
    ADD CONSTRAINT order_item_pkey PRIMARY KEY (order_id, item_id);


--
-- Name: restaurant_owner restaurant_owner_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.restaurant_owner
    ADD CONSTRAINT restaurant_owner_pkey PRIMARY KEY (user_id);


--
-- Name: restaurant_owner restaurant_owner_tax_id_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.restaurant_owner
    ADD CONSTRAINT restaurant_owner_tax_id_key UNIQUE (tax_id);


--
-- Name: restaurant restaurant_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.restaurant
    ADD CONSTRAINT restaurant_pkey PRIMARY KEY (restaurant_id);


--
-- Name: idx_driver_location_gist; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_driver_location_gist ON public.driver USING gist (location);


--
-- Name: idx_restaurant_location_gist; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_restaurant_location_gist ON public.restaurant USING gist (location);


--
-- Name: order_item trg_order_item_snapshot; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_order_item_snapshot BEFORE INSERT ON public.order_item FOR EACH ROW EXECUTE FUNCTION public.fn_snapshot_item_price_and_total();


--
-- Name: ORDER trg_order_lifecycle; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_order_lifecycle BEFORE UPDATE ON public."ORDER" FOR EACH ROW EXECUTE FUNCTION public.fn_enforce_order_lifecycle();


--
-- Name: ORDER ORDER_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."ORDER"
    ADD CONSTRAINT "ORDER_customer_id_fkey" FOREIGN KEY (customer_id) REFERENCES public.customer(user_id);


--
-- Name: ORDER ORDER_driver_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."ORDER"
    ADD CONSTRAINT "ORDER_driver_id_fkey" FOREIGN KEY (driver_id) REFERENCES public.driver(user_id);


--
-- Name: ORDER ORDER_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public."ORDER"
    ADD CONSTRAINT "ORDER_restaurant_id_fkey" FOREIGN KEY (restaurant_id) REFERENCES public.restaurant(restaurant_id);


--
-- Name: customer customer_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."USER"(user_id) ON DELETE CASCADE;


--
-- Name: driver driver_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.driver
    ADD CONSTRAINT driver_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."USER"(user_id) ON DELETE CASCADE;


--
-- Name: menu_item menu_item_restaurant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.menu_item
    ADD CONSTRAINT menu_item_restaurant_id_fkey FOREIGN KEY (restaurant_id) REFERENCES public.restaurant(restaurant_id);


--
-- Name: order_item order_item_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_item
    ADD CONSTRAINT order_item_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.menu_item(item_id);


--
-- Name: order_item order_item_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_item
    ADD CONSTRAINT order_item_order_id_fkey FOREIGN KEY (order_id) REFERENCES public."ORDER"(order_id) ON DELETE CASCADE;


--
-- Name: restaurant restaurant_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.restaurant
    ADD CONSTRAINT restaurant_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.restaurant_owner(user_id);


--
-- Name: restaurant_owner restaurant_owner_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.restaurant_owner
    ADD CONSTRAINT restaurant_owner_user_id_fkey FOREIGN KEY (user_id) REFERENCES public."USER"(user_id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict 0d4FgVgABYrECpz4daZYSLsZZEwfmgv47owfcVD4EFq5EqjgsbcvKHmlicdIZBQ

