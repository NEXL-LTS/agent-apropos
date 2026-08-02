module AgentApropos
  def self.find_repo_root(start : Path) : Path?
    current = start.expand
    loop do
      return current if File.exists?(current.join(".git").to_s)
      parent = current.parent
      return nil if parent == current
      current = parent
    end
  end
end
