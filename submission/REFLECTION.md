# REFLECTION — Day 18 Lakehouse Lab

**Anti-pattern dễ vướng nhất:** Thiếu lịch sử dữ liệu (*Versioning*) — không đọc lại được trạng thái bảng ở quá khứ.

**Vì sao dữ liệu team tôi dính:** VLearn Tutor trả lời kèm citation trên học liệu PDF trích theo trang; Topic Interest Map cho re-cluster và đổi tên cụm. Học liệu, chatlog nạp theo đợt, chat mới ghi thẳng SQLite — nạp lại là ghi đè. Sau khi học liệu cập nhật hoặc cụm đổi tên, không còn mốc nào nói câu trả lời tuần trước dựa trên bản nào; giữ bằng chứng chỉ còn cách copy cả thư mục — lãng phí slide ước tính 30×.

**Bằng chứng tôi tự đo:**
- NB8: pin version bảng cho một training run rồi replay đúng version đó, kết quả khớp tuyệt đối — provenance là metadata, không phải bản sao.
- NB3: `history()` giữ ≥ 5 version kể cả sau RESTORE; rollback đưa `score < 0` về 0, không nhân bản bảng.

**Team tôi sẽ đổi gì:** Đưa corpus và hội thoại về Delta, mỗi đợt ingest là một commit; Tutor ghi `table_version` vào log câu trả lời. Kiểm chứng: replay 20 câu cũ tại version đã pin, đòi citation trùng 100%.
