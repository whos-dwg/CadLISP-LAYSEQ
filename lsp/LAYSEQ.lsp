;;; ============================================================
;;; LAYSEQ.lsp
;;; Batch rename selected layouts by current tab order.
;;;
;;; Command: LAYSEQ
;;;
;;; Example:
;;; Prefix        : A-
;;; Start number  : 1
;;; Number digits : 2
;;;
;;; Result:
;;; A-01
;;; A-02
;;; A-03
;;; ============================================================

(vl-load-com)

(defun LAYSEQ:GetLayouts (/ doc layouts result item)
  (setq doc     (vla-get-ActiveDocument (vlax-get-acad-object))
        layouts (vla-get-Layouts doc)
        result  '()
  )

  (vlax-for item layouts
    (if (/= (strcase (vla-get-Name item)) "MODEL")
      (setq result
        (cons
          (list
            (vla-get-TabOrder item)
            (vla-get-Name item)
            item
          )
          result
        )
      )
    )
  )

  (vl-sort result
    '(lambda (a b)
       (< (car a) (car b))
     )
  )
)

(defun LAYSEQ:WriteDCL (/ file path)
  (setq path (vl-filename-mktemp "LAYSEQ_" nil ".dcl"))

  (if (setq file (open path "w"))
    (progn
      (foreach line
        '(
          "layseq_dialog : dialog {"
          "  label = \"Batch Layout Rename\";"
          "  : column {"
          "    : boxed_column {"
          "      label = \"Select layouts\";"
          "      : list_box {"
          "        key = \"layouts\";"
          "        width = 48;"
          "        height = 18;"
          "        multiple_select = true;"
          "        fixed_width_font = true;"
          "      }"
          "    }"
          "    : boxed_column {"
          "      label = \"Naming\";"
          "      : row {"
          "        : text { label = \"Prefix:\"; width = 16; }"
          "        : edit_box { key = \"prefix\"; width = 25; }"
          "      }"
          "      : row {"
          "        : text { label = \"Start number:\"; width = 16; }"
          "        : edit_box { key = \"start\"; width = 25; }"
          "      }"
          "      : row {"
          "        : text { label = \"Number digits:\"; width = 16; }"
          "        : edit_box { key = \"digits\"; width = 25; }"
          "      }"
          "    }"
          "    : text {"
          "      label = \"Use Ctrl or Shift to select multiple layouts.\";"
          "    }"
          "    spacer;"
          "    ok_cancel;"
          "  }"
          "}"
        )
        (write-line line file)
      )
      (close file)
      path
    )
  )
)

(defun LAYSEQ:ParseSelection (value / result)
  (if (and value (/= value ""))
    (progn
      (setq result
        (vl-catch-all-apply
          'read
          (list (strcat "(" value ")"))
        )
      )
      (if (vl-catch-all-error-p result)
        nil
        result
      )
    )
  )
)

(defun LAYSEQ:IntegerStringP (value / number)
  (and
    value
    (/= value "")
    (setq number (distof value 2))
    (= number (fix number))
  )
)

(defun LAYSEQ:ValidLayoutNameP (name / invalidChars valid)
  (setq invalidChars '("<" ">" "/" "\\" "\"" ":" ";" "?" "*" "|" "=" "`")
        valid T
  )

  (if (= name "")
    (setq valid nil)
  )

  (foreach char invalidChars
    (if (vl-string-search char name)
      (setq valid nil)
    )
  )

  valid
)

(defun LAYSEQ:PadNumber (number digits / value)
  (setq value (itoa number))
  (while (< (strlen value) digits)
    (setq value (strcat "0" value))
  )
  value
)

(defun LAYSEQ:MemberCI (name names)
  (if
    (vl-some
      '(lambda (item)
         (= (strcase name) (strcase item))
       )
      names
    )
    T
    nil
  )
)

(defun LAYSEQ:UniqueTempName (usedNames index / candidate counter)
  (setq counter 0)

  (while
    (progn
      (setq candidate
        (strcat
          "__LAYSEQ_TEMP_"
          (itoa index)
          "_"
          (itoa counter)
          "__"
        )
      )

      (if (LAYSEQ:MemberCI candidate usedNames)
        (progn
          (setq counter (1+ counter))
          T
        )
        nil
      )
    )
  )

  candidate
)

(defun LAYSEQ:ShowDialog
  (layoutData / dclPath dclId result index item)

  (setq dclPath (LAYSEQ:WriteDCL))

  (if (not dclPath)
    nil
    (progn
      (setq dclId (load_dialog dclPath))

      (if
        (or
          (< dclId 0)
          (not (new_dialog "layseq_dialog" dclId))
        )
        (progn
          (if (>= dclId 0)
            (unload_dialog dclId)
          )
          (vl-file-delete dclPath)
          nil
        )
        (progn
          (start_list "layouts")
          (setq index 1)

          (foreach item layoutData
            (add_list
              (strcat
                (if (< index 10) "0" "")
                (itoa index)
                "  "
                (cadr item)
              )
            )
            (setq index (1+ index))
          )

          (end_list)

          (set_tile "start" "1")
          (set_tile "digits" "2")

          (setq
            *LAYSEQ:selected* nil
            *LAYSEQ:prefix*   ""
            *LAYSEQ:start*    "1"
            *LAYSEQ:digits*   "2"
          )

          (action_tile
            "accept"
            (strcat
              "(setq *LAYSEQ:selected* (get_tile \"layouts\"))"
              "(setq *LAYSEQ:prefix*   (get_tile \"prefix\"))"
              "(setq *LAYSEQ:start*    (get_tile \"start\"))"
              "(setq *LAYSEQ:digits*   (get_tile \"digits\"))"
              "(done_dialog 1)"
            )
          )

          (action_tile "cancel" "(done_dialog 0)")
          (setq result (start_dialog))

          (unload_dialog dclId)
          (vl-file-delete dclPath)

          (if (= result 1)
            (list
              (LAYSEQ:ParseSelection *LAYSEQ:selected*)
              *LAYSEQ:prefix*
              *LAYSEQ:start*
              *LAYSEQ:digits*
            )
            nil
          )
        )
      )
    )
  )
)

(defun LAYSEQ:RenameLayouts
  (layoutData selected prefix startNumber digits
   / selectedData finalNames allNames unselectedNames item index
     newName tempName tempNames errorMessage)

  (setq selectedData '())

  (foreach index selected
    (if (and (>= index 0) (< index (length layoutData)))
      (setq selectedData
        (append selectedData (list (nth index layoutData)))
      )
    )
  )

  (if (null selectedData)
    (progn
      (prompt "\nNo layouts selected.")
      nil
    )
    (progn
      (setq finalNames '()
            index      0
            errorMessage nil
      )

      (foreach item selectedData
        (setq newName
          (strcat
            prefix
            (LAYSEQ:PadNumber
              (+ startNumber index)
              digits
            )
          )
        )

        (if (not (LAYSEQ:ValidLayoutNameP newName))
          (setq errorMessage
            (strcat "Invalid layout name: " newName)
          )
        )

        (setq finalNames
          (append finalNames (list newName))
        )

        (setq index (1+ index))
      )

      (setq allNames
        (mapcar
          '(lambda (layoutItem)
             (cadr layoutItem)
           )
          layoutData
        )
      )

      (setq unselectedNames '())

      (foreach item layoutData
        (if
          (not
            (vl-some
              '(lambda (selectedItem)
                 (eq (caddr item) (caddr selectedItem))
               )
              selectedData
            )
          )
          (setq unselectedNames
            (cons (cadr item) unselectedNames)
          )
        )
      )

      (if (not errorMessage)
        (foreach newName finalNames
          (if
            (> 
              (length
                (vl-remove-if-not
                  '(lambda (testName)
                     (= (strcase testName) (strcase newName))
                   )
                  finalNames
                )
              )
              1
            )
            (setq errorMessage
              (strcat "Duplicate target layout name: " newName)
            )
          )
        )
      )

      (if (not errorMessage)
        (foreach newName finalNames
          (if (LAYSEQ:MemberCI newName unselectedNames)
            (setq errorMessage
              (strcat "Layout name already exists: " newName)
            )
          )
        )
      )

      (if errorMessage
        (progn
          (prompt (strcat "\n" errorMessage))
          nil
        )
        (progn
          (setq tempNames '()
                index     0
          )

          (foreach item selectedData
            (setq tempName
              (LAYSEQ:UniqueTempName
                (append allNames tempNames finalNames)
                index
              )
            )

            (vla-put-Name (caddr item) tempName)

            (setq tempNames
              (append tempNames (list tempName))
            )

            (setq index (1+ index))
          )

          (setq index 0)

          (foreach item selectedData
            (vla-put-Name
              (caddr item)
              (nth index finalNames)
            )
            (setq index (1+ index))
          )

          (vla-Regen
            (vla-get-ActiveDocument (vlax-get-acad-object))
            1
          )

          (prompt
            (strcat
              "\n"
              (itoa (length selectedData))
              " layout(s) renamed successfully."
            )
          )
          T
        )
      )
    )
  )
)

(defun c:LAYSEQ
  (/ *error* layoutData dialogResult selected
     prefix startText digitsText startNumber digits)

  (vl-load-com)

  (defun *error* (message)
    (if
      (and
        message
        (/= message "Function cancelled")
        (/= message "quit / exit abort")
      )
      (prompt (strcat "\nError: " message))
    )
    (princ)
  )

  (setq layoutData (LAYSEQ:GetLayouts))

  (cond
    ((null layoutData)
      (prompt "\nNo paper-space layouts found.")
    )

    ((null (setq dialogResult (LAYSEQ:ShowDialog layoutData)))
      (prompt "\nCommand cancelled.")
    )

    (T
      (setq selected   (nth 0 dialogResult)
            prefix     (nth 1 dialogResult)
            startText  (nth 2 dialogResult)
            digitsText (nth 3 dialogResult)
      )

      (cond
        ((null selected)
          (prompt "\nNo layouts selected.")
        )

        ((not (LAYSEQ:IntegerStringP startText))
          (prompt "\nStart number must be an integer.")
        )

        ((not (LAYSEQ:IntegerStringP digitsText))
          (prompt "\nNumber digits must be an integer.")
        )

        (T
          (setq startNumber (fix (distof startText 2))
                digits      (fix (distof digitsText 2))
          )

          (cond
            ((< startNumber 0)
              (prompt "\nStart number cannot be negative.")
            )

            ((or (< digits 1) (> digits 12))
              (prompt "\nNumber digits must be between 1 and 12.")
            )

            (T
              (LAYSEQ:RenameLayouts
                layoutData
                selected
                prefix
                startNumber
                digits
              )
            )
          )
        )
      )
    )
  )

  (princ)
)

(prompt "\nLAYSEQ loaded. Type LAYSEQ to batch rename layouts.")
(princ)
