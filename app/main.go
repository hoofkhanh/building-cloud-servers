package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Task struct {
	ID    int64  `json:"id"`
	Title string `json:"title"`
}

var db *pgxpool.Pool

func main() {
	dsn := os.Getenv("DATABASE_URL")

	if dsn == "" {
		dsn = "postgres://postgres:postgres@localhost:5432/taskdb?sslmode=disable"
	}

	var err error
	db, err = pgxpool.New(context.Background(), dsn)
	if err != nil {
		log.Printf("Database configuration error: %v", err)
		db = nil
	}

	if db != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		if err := db.Ping(ctx); err != nil {
			log.Printf("Database unavailable: %v", err)
			db.Close()
			db = nil
		} else {
			log.Println("Connected to PostgreSQL")

			_, err = db.Exec(ctx,
				`CREATE TABLE IF NOT EXISTS tasks (
                    id BIGSERIAL PRIMARY KEY,
                    title TEXT NOT NULL
                )`)

			if err != nil {
				log.Printf("Could not initialize database: %v", err)
				db.Close()
				db = nil
			}
		}
	}

	http.HandleFunc("GET /tasks", getTasks)
	http.HandleFunc("GET /hello", sayHello)
	http.HandleFunc("POST /tasks", createTask)
	http.HandleFunc("DELETE /tasks/{id}", deleteTask)

	log.Println("Listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}

func sayHello(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	json.NewEncoder(w).Encode(map[string]string{
		"message": "Hello, World!",
	})
}

func getTasks(w http.ResponseWriter, r *http.Request) {
	rows, err := db.Query(r.Context(), `SELECT id, title FROM tasks ORDER BY id`)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	defer rows.Close()

	tasks := []Task{}
	for rows.Next() {
		var t Task
		if err := rows.Scan(&t.ID, &t.Title); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		tasks = append(tasks, t)
	}
	json.NewEncoder(w).Encode(tasks)
}

func createTask(w http.ResponseWriter, r *http.Request) {
	var t Task
	if err := json.NewDecoder(r.Body).Decode(&t); err != nil || t.Title == "" {
		http.Error(w, "title is required", http.StatusBadRequest)
		return
	}
	err := db.QueryRow(r.Context(),
		`INSERT INTO tasks (title) VALUES ($1) RETURNING id`, t.Title).Scan(&t.ID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(t)
}

func deleteTask(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		http.Error(w, "invalid id", http.StatusBadRequest)
		return
	}
	tag, err := db.Exec(r.Context(), `DELETE FROM tasks WHERE id = $1`, id)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	if tag.RowsAffected() == 0 {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
