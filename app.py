import psycopg2
from psycopg2.extras import RealDictCursor
from flask import Flask, render_template, request, redirect, url_for, flash, session
import random

app = Flask(__name__)
app.secret_key = 'super_secret_session_key'

# Cấu hình Database (Thay đổi thông tin cho khớp với máy của bạn)
DB_CONFIG = {
    'dbname': 'food_delivery_db',
    'user': 'postgres',
    'password': 'qwer',
    'host': 'localhost',
    'port': '5432'
}

def get_db():
    return psycopg2.connect(**DB_CONFIG)

def generate_id(prefix):
    """Hệ thống sử dụng VARCHAR(10) với 3 ký tự đầu xác định loại PK"""
    return f"{prefix}{random.randint(1000000, 9999999)}"

# ==========================================
# CONTEXT PROCESSOR: Dùng chung cho mọi trang (Giả lập chuyển tài khoản)
# ==========================================
@app.context_processor
def inject_users():
    """Lấy danh sách tất cả USER để làm Menu Dropdown chuyển đổi tài khoản"""
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute("SELECT user_id, full_name, user_type FROM \"USER\" ORDER BY user_type, user_id")
    all_users = cur.fetchall()
    cur.close()
    conn.close()
    return dict(all_users=all_users, current_user_id=session.get('user_id'), current_user_type=session.get('user_type'))

@app.route('/switch_user', methods=['POST'])
def switch_user():
    """Logic chuyển đổi tài khoản linh hoạt"""
    user_id = request.form.get('user_id')
    user_type = request.form.get('user_type')
    
    if user_id == 'ADMIN':
        session['user_id'] = 'ADMIN'
        session['user_type'] = 'ADMIN'
        return redirect(url_for('admin_view'))
    
    session['user_id'] = user_id
    session['user_type'] = user_type
    
    # Điều hướng về đúng Dashboard của role đó
    if user_type == 'CUSTOMER': return redirect(url_for('customer_view'))
    if user_type == 'DRIVER': return redirect(url_for('driver_view'))
    if user_type == 'RESTAURANT_OWNER': return redirect(url_for('owner_view'))
    return redirect(url_for('index'))

# ==========================================
# CÁC ROUTE GIAO DIỆN
# ==========================================
@app.route('/')
def index():
    return render_template('index.html')

# ----------------- 1. CUSTOMER -----------------
@app.route('/customer')
def customer_view():
    if session.get('user_type') != 'CUSTOMER': return redirect(url_for('index'))
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    # Chỉ hiển thị món ăn có stock_status = 'AVAILABLE'
    cur.execute("""
        SELECT m.item_id, m.item_name, m.current_price, r.restaurant_id, r.restaurant_name
        FROM MENU_ITEM m JOIN RESTAURANT r ON m.restaurant_id = r.restaurant_id
        WHERE m.stock_status = 'AVAILABLE'
    """)
    menu = cur.fetchall()
    
    # Đơn hàng của khách này
    cur.execute('SELECT * FROM "ORDER" WHERE customer_id = %s ORDER BY placed_at DESC', (session['user_id'],))
    orders = cur.fetchall()
    cur.close()
    conn.close()
    return render_template('customer.html', menu=menu, orders=orders)

@app.route('/customer/place_order', methods=['POST'])
def customer_place_order():
    item_id = request.form['item_id']
    restaurant_id = request.form['restaurant_id']
    quantity = int(request.form.get('quantity', 1))
    customer_id = session['user_id']
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    try:
        # Tự động gán tài xế rảnh gần nhất bằng truy vấn không gian PostGIS (GEOMETRY <->)
        cur.execute("""
            SELECT d.user_id FROM DRIVER d CROSS JOIN RESTAURANT r
            WHERE r.restaurant_id = %s AND d.is_active_order = FALSE
            ORDER BY d.location <-> r.location LIMIT 1
        """, (restaurant_id,))
        driver = cur.fetchone()
        driver_id = driver['user_id'] if driver else None

        # Khởi tạo Order với trạng thái PENDING
        order_id = generate_id('ORD')
        cur.execute("""
            INSERT INTO "ORDER" (order_id, customer_id, restaurant_id, driver_id, order_status, shipping_fee, delivery_address)
            VALUES (%s, %s, %s, %s, 'PENDING', 15000, (SELECT default_delivery_address FROM CUSTOMER WHERE user_id = %s))
        """, (order_id, customer_id, restaurant_id, driver_id, customer_id))
        
        # Insert Order_Item (Trigger DB tự động snapshot giá trị current_price)
        cur.execute("INSERT INTO ORDER_ITEM (order_id, item_id, quantity) VALUES (%s, %s, %s)", (order_id, item_id, quantity))
        conn.commit()
        flash(f"Tạo đơn {order_id} thành công! (PENDING)", "success")
    except Exception as e:
        conn.rollback()
        flash(f"Lỗi: {e}", "danger")
    finally:
        cur.close()
        conn.close()
    return redirect(url_for('customer_view'))

# ----------------- 2. RESTAURANT OWNER -----------------
@app.route('/owner')
def owner_view():
    if session.get('user_type') != 'RESTAURANT_OWNER': return redirect(url_for('index'))
    owner_id = session['user_id']
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute("SELECT * FROM RESTAURANT WHERE owner_id = %s", (owner_id,))
    restaurants = cur.fetchall()
    
    # Lấy MENU của nhà hàng thuộc chủ này
    cur.execute("""
        SELECT m.*, r.restaurant_name FROM MENU_ITEM m 
        JOIN RESTAURANT r ON m.restaurant_id = r.restaurant_id 
        WHERE r.owner_id = %s ORDER BY m.item_id DESC
    """, (owner_id,))
    menus = cur.fetchall()

    # Lấy các ORDER liên quan đến nhà hàng của chủ này
    cur.execute("""
        SELECT o.* FROM "ORDER" o JOIN RESTAURANT r ON o.restaurant_id = r.restaurant_id
        WHERE r.owner_id = %s ORDER BY o.placed_at DESC
    """, (owner_id,))
    orders = cur.fetchall()
    
    cur.close()
    conn.close()
    return render_template('owner.html', restaurants=restaurants, menus=menus, orders=orders)

@app.route('/owner/menu/add', methods=['POST'])
def owner_add_menu():
    """Owner có quyền tạo thêm thực đơn cho nhà hàng của mình"""
    item_id = generate_id('ITM')
    name = request.form['item_name']
    price = request.form['current_price']
    status = request.form['stock_status']
    rest_id = request.form['restaurant_id']
    
    conn = get_db()
    cur = conn.cursor()
    try:
        cur.execute("""
            INSERT INTO MENU_ITEM (item_id, restaurant_id, item_name, current_price, stock_status) 
            VALUES (%s, %s, %s, %s, %s)
        """, (item_id, rest_id, name, price, status))
        conn.commit()
        flash("Thêm món ăn thành công", "success")
    except Exception as e:
        conn.rollback()
        flash(f"Lỗi thêm món: {e}", "danger")
    finally:
        cur.close()
        conn.close()
    return redirect(url_for('owner_view'))

@app.route('/owner/order/update', methods=['POST'])
def owner_update_order():
    """Owner cập nhật trạng thái đơn (PENDING -> CONFIRMED -> PREPARING -> READY)"""
    order_id = request.form['order_id']
    new_status = request.form['new_status']
    conn = get_db()
    cur = conn.cursor()
    try:
        cur.execute('UPDATE "ORDER" SET order_status = %s WHERE order_id = %s', (new_status, order_id))
        conn.commit()
        flash(f"Cập nhật đơn {order_id} thành {new_status}", "success")
    except Exception as e:
        conn.rollback()
        flash(f"Lỗi State Machine: {e}", "danger")
    finally:
        cur.close()
        conn.close()
    return redirect(url_for('owner_view'))

# ----------------- 3. DRIVER -----------------
@app.route('/driver')
def driver_view():
    if session.get('user_type') != 'DRIVER': return redirect(url_for('index'))
    driver_id = session['user_id']
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute('SELECT * FROM "ORDER" WHERE driver_id = %s AND order_status NOT IN (\'DELIVERED\', \'CANCELLED\')', (driver_id,))
    orders = cur.fetchall()
    cur.close()
    conn.close()
    return render_template('driver.html', orders=orders)

@app.route('/driver/order/update', methods=['POST'])
def driver_update_order():
    """Driver cập nhật (READY -> PICKED_UP -> DELIVERED)"""
    order_id = request.form['order_id']
    new_status = request.form['new_status']
    conn = get_db()
    cur = conn.cursor()
    try:
        cur.execute('UPDATE "ORDER" SET order_status = %s WHERE order_id = %s', (new_status, order_id))
        conn.commit()
        flash(f"Cập nhật đơn {order_id} thành {new_status}", "success")
    except Exception as e:
        conn.rollback()
        flash(f"Lỗi hệ thống: {e}", "danger")
    finally:
        cur.close()
        conn.close()
    return redirect(url_for('driver_view'))

# ----------------- 4. ADMIN TOÀN QUYỀN -----------------
@app.route('/admin')
def admin_view():
    if session.get('user_type') != 'ADMIN': return redirect(url_for('index'))
    
    conn = get_db()
    cur = conn.cursor(cursor_factory=RealDictCursor)
    cur.execute('SELECT * FROM "USER"')
    users = cur.fetchall()
    cur.execute('SELECT * FROM MENU_ITEM')
    menus = cur.fetchall()
    cur.close()
    conn.close()
    return render_template('admin.html', users=users, menus=menus)

@app.route('/admin/delete_user', methods=['POST'])
def admin_delete_user():
    user_id = request.form['user_id']
    conn = get_db()
    cur = conn.cursor()
    try:
        cur.execute('DELETE FROM "USER" WHERE user_id = %s', (user_id,))
        conn.commit()
        flash(f"Đã xóa User {user_id}", "success")
    except Exception as e:
        conn.rollback()
        flash(f"Không thể xóa User (vướng khóa ngoại): {e}", "danger")
    finally:
        cur.close()
        conn.close()
    return redirect(url_for('admin_view'))

if __name__ == '__main__':
    app.run(debug=True, port=5000)