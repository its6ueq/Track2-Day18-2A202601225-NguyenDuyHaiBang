# screenshots/

Rubric cần **ít nhất một** ảnh, chọn một trong hai đường:

## A. Đường Spark — MinIO console

Stack đang chạy thì mở http://localhost:9001 (`minioadmin` / `minioadmin`),
vào bucket `lakehouse` → `_smoke/` hoặc `bronze/llm_calls_raw/`, chụp sao cho
thấy **thư mục `_delta_log/`** và layout bucket.

```bash
make wsl-spark-up      # nếu stack chưa chạy
```

Lưu ảnh vào đây, ví dụ `minio-delta-log.png`.

## B. Đường lightweight — cây thư mục + một commit JSON

Trên WSL dữ liệu nằm ngoài repo (drvfs không ghi nổi NB7 — xem README mục
"Chạy trên WSL2"), nên lấy đường dẫn thật bằng `make wsl-status`:

```bash
LH=~/.cache/day18-lakehouse/_lakehouse
find "$LH" -maxdepth 3 | sort | head -40          # Ubuntu 26.04 không có sẵn `tree`
head -20 "$LH"/bronze/llm_calls_raw/_delta_log/00000000000000000000.json
```

Muốn ra đúng dạng cây như rubric mô tả thì cài trước: `sudo apt install -y tree`,
rồi `tree -L 3 "$LH" | head -40`.

Chụp màn hình terminal đang hiện cả hai lệnh trên. Lưu vào đây, ví dụ
`lakehouse-tree.png`.

> Ảnh là deliverable — file `.png`/`.jpg` thật, không phải dán text vào `.md`.
