module AgentApropos
  record Check, status : Check::Status, name : String, detail : String do
    enum Status
      Ok
      Warn
      Fail
    end
  end
end
