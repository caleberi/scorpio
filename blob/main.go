package main

import (
	"context"
	"io/fs"
	"log"
	"os"
	"path/filepath"

	"github.com/caleberi/kloudinary"
	"github.com/go-co-op/gocron/v2"
)

func main() {
	infoLogger := log.New(os.Stdout, "INFO", log.Ldate|log.Lshortfile)
	errorLogger := log.New(os.Stderr, "ERROR", log.Ldate|log.Lshortfile)

	scheduler, err := gocron.NewScheduler()
	if err != nil {
		errorLogger.Fatalf("could not create a scheduler : err= %s\n", err)
	}

	cld, err := kloudinary.NewAssetUploadManager(
		os.Getenv("CLOUDINARY_CLOUDNAME"),
		os.Getenv("CLOUDINARY_API_KEY"),
		os.Getenv("CLOUDINARY_API_SECRET"),
	)
	if err != nil {
		errorLogger.Fatalf("could not create a cloudinary manager : err= %s\n", err)
	}

	job, err := scheduler.NewJob(
		gocron.DailyJob(2, gocron.NewAtTimes(gocron.NewAtTime(24, 0, 0))),
		gocron.NewTask(
			func(cld *kloudinary.AssetUploadManager, path string) {
				ctx := context.Background()
				files, err := findBatchFiles(path)
				if err != nil {
					errorLogger.Printf("failed to find batch files: %v\n", err)
					return
				}

				results := cld.UploadMultipleFiles(ctx, files...)
				infoLogger.Printf("Uploaded %d file\n", len(results))
			},
			&cld, os.Getenv("UPLOAD_PATH"),
		),
	)
	if err != nil {
		errorLogger.Fatalf("could not create an upload job : err= %s\n", err)
	}

	infoLogger.Printf("Job[%s] has started.\n", job.ID().String())
	scheduler.Start()
	for scheduler.JobsWaitingInQueue() > 0 {
	}
}

func findBatchFiles(dir string) ([]interface{}, error) {
	var files []interface{}
	err := filepath.Walk(dir, func(path string, info fs.FileInfo, err error) error {
		if err != nil {
			return err
		}
		if !info.IsDir() && filepath.Ext(info.Name()) == ".batch" {
			files = append(files, path)
		}
		return nil
	})
	return files, err
}
