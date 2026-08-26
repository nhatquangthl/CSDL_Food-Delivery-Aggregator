# Food Delivery Aggregator SYSTEM (Mini-DoorDash)



> \*\*Học phần:\*\* INT1313 (Database Systems)

> \*\*Giảng viên hướng dẫn:\*\* Lê Hà Thanh

> \*\*Nhóm thực hiện:\*\* F\&F



\## Tổng quan dự án (Project Overview)

Dự án này thiết kế và xây dựng một hệ cơ sở dữ liệu quan hệ cho nền tảng giao nhận đồ ăn (Food Delivery Aggregator) hoạt động theo mô hình tương tự ShopeeFood, GrabFood hay DoorDash. Hệ thống quản lý toàn diện vòng đời của một đơn hàng, từ khi khách hàng tìm kiếm nhà hàng, đặt món, cho đến khi tài xế nhận đơn và hoàn tất giao hàng.



\*\*Các tính năng nghiệp vụ cốt lõi của CSDL:\*\*

\- \*\*Order State Processing:\*\* Kiểm soát chặt chẽ trạng thái đơn hàng (PENDING -> CONFIRMED -> PREPARING -> READY\_FOR\_PICKUP -> PICKED\_UP -> DELIVERED) tuân thủ tính chất ACID.

\- \*\*Dynamic Pricing Snapshot:\*\* Lưu trữ ảnh chụp giá trị món ăn tại thời điểm đặt hàng để đảm bảo tính toàn vẹn tài chính.

\- \*\*Spatial \& Status Querying:\*\* Xử lý điều hướng tài xế dựa trên vị từ trạng thái (`is\_active\_order = TRUE/FALSE`).

\- \*\*Rating Aggregation:\*\* Tổng hợp dữ liệu đánh giá chất lượng dịch vụ ở cấp độ đơn hàng (Order-level rating).



\## Thành viên nhóm

| STT | Họ và Tên | Mã Sinh Viên | Vai trò \& Nhiệm vụ |

|:---:|:---|:---|:---|

| 1 | Thân Lê Nhật Quang | N25DCAT099 | Data Modeling (EER), Data Dictionary, Lead DB Design |

| 2 | Nguyễn Tấn Tài | N25DCAT101 | Logical Design, SQL Scripts \& Constraints |

| 3 | Trần Thiên Hoàng Quân | N25DCAT097 | Query Optimization, Report Documentation |



\## Cấu trúc Repository (Theo chuẩn ISO/IEC/IEEE)

Dự án được tổ chức theo tiêu chuẩn tài liệu công nghiệp (Industrial Documentation Standards):

\- `docs/`: Chứa tài liệu đặc tả yêu cầu (System Requirements), Business Rules và Data Dictionary (tuân thủ chuẩn định nghĩa dữ liệu).

\- `diagrams/`: Chứa sơ đồ khái niệm (Conceptual EER Diagram) áp dụng quy tắc chuyên môn hóa (Specialization) của Elmasri và sơ đồ vật lý (IE Crow's Foot).

\- `sql/`: \_(Đang phát triển)\_ Chứa các file script DDL (khởi tạo bảng), DML (dữ liệu mock), Triggers và các câu truy vấn phân tích dữ liệu.



\## Trạng thái dự án

\- \[x] \*\*Giai đoạn 1:\*\* Phân tích yêu cầu và định nghĩa Business Rules.

\- \[x] \*\*Giai đoạn 1:\*\* Xây dựng Data Dictionary chi tiết kèm Ràng buộc.

\- \[x] \*\*Giai đoạn 2:\*\* Thiết kế Conceptual EER Diagram.

\- \[ ] \*\*Giai đoạn 2:\*\* Ánh xạ Logical Model (Relational Schema).

\- \[ ] \*\*Giai đoạn 3:\*\* Viết SQL Scripts và Tối ưu hóa truy vấn.

